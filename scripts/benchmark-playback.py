#!/usr/bin/env python3
"""Measure a cold start through the real companion encoder, HTTP, and native AVFoundation.

Requires macOS, Xcode, Docker, and a built server image (make server-image).
  python3 scripts/benchmark-playback.py --baseline-ref HEAD --runs 3

The isolated fixture uses synthetic, realtime-paced lossless audio. It never connects
to your music server, uses saved credentials, or changes the installed app.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]

SERVER = r'''
import asyncio
import importlib.util
from pathlib import Path
import sys
import tempfile
from aiohttp import web

root = Path('/companion/music_assistant_one')
spec = importlib.util.spec_from_file_location('benchmark_adapter', root / '__init__.py', submodule_search_locations=[str(root)])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

async def authenticate(request):
    if request.headers.get('Authorization') != 'Bearer benchmark':
        raise web.HTTPUnauthorized()
    return module.AudioIdentity('benchmark', credential='benchmark')
async def revalidate(identity):
    return True
async def render(identity, uri, destination, stream):
    from music_assistant_models.enums import ContentType
    from music_assistant_models.media_items.audio_format import AudioFormat
    pcm = AudioFormat(content_type=ContentType.PCM_S16LE, sample_rate=44100, bit_depth=16, channels=2)
    async def source():
        for _ in range(320):
            yield bytes(8820)
            await asyncio.sleep(0.05)
    await module.encode(source(), pcm, destination, stream)
async def application():
    service = module.AudioService(Path(tempfile.mkdtemp()), authenticate, revalidate, render)
    await service.start()
    app = web.Application()
    app.router.add_get('/one/v1/capabilities', service.capabilities)
    app.router.add_post('/one/v1/resolve', service.resolve)
    app.router.add_get('/one/v1/file.flac', service.file)
    app.router.add_get('/one/v1/audio/{ticket}.flac', service.audio)
    app.router.add_get('/one/v1/stream/{ticket}/{file}', service.stream)
    async def reset(request):
        await authenticate(request)
        await service.close()
        return web.Response(status=204)
    app.router.add_post('/benchmark/reset', reset)
    async def cleanup(app):
        await service.close()
    app.on_cleanup.append(cleanup)
    return app
web.run_app(application(), host='0.0.0.0', port=8096, access_log=None)
'''

NATIVE = r'''
import Foundation
import MusicAssistantCore

@main struct PlaybackBenchmark {
    @MainActor static func main() async throws {
        let address = try ServerAddress(CommandLine.arguments[1])
        let downloads = AudioDownloads(sessionIdentifier: "one.benchmark." + UUID().uuidString)
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(access: IndependentAudioClient(server: address, token: "benchmark"), store: nil)
        player.online = true
        let song = MediaItem(.object(["uri": .string("fixture://track/" + UUID().uuidString), "name": .string("Benchmark"), "duration": .number(16)]))
        let start = ContinuousClock.now
        player.insert([song], option: "replace")
        for _ in 0 ..< 1000 {
            if player.state.position > 0.1, !player.isBuffering { break }
            if let error = player.error { throw MAError.message(error) }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard player.state.position > 0.1, !player.isBuffering else {
            throw MAError.message("Playback did not advance before the benchmark deadline.")
        }
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("{\"seconds\":\(seconds)}")
        player.stop(clear: true)
        await player.flushPersistence()
    }
}
'''


def run(arguments, **kwargs):
    try:
        return subprocess.run(arguments, cwd=ROOT, check=True, text=True, **kwargs)
    except subprocess.CalledProcessError as error:
        for output in [error.stdout, error.stderr]:
            if output:
                print(output, file=sys.stderr)
        raise


def measure(label, companion, device, temporary, binary_directory, image, count):
    executable = temporary / (label + "-player")
    aggregate = binary_directory / "MusicAssistantCore.o"
    objects = [aggregate] if aggregate.exists() else list(binary_directory.glob("MusicAssistantCore.build/*.swift.o"))
    if not objects:
        raise RuntimeError("Couldn't locate the built MusicAssistantCore object files")
    modules = binary_directory if (binary_directory / "MusicAssistantCore.swiftmodule").exists() else binary_directory / "Modules"
    run(["swiftc", "-parse-as-library", "-swift-version", "6", "-I", str(modules), *map(str, objects),
         "App/Services/CredentialStore.swift", "App/Services/AudioDownloads.swift", str(device),
         str(temporary / "benchmark.swift"), "-o", str(executable)], capture_output=True)
    container = run(["docker", "run", "--rm", "--pull", "never", "--detach", "--publish", "127.0.0.1::8096",
                     "--entrypoint", "python", "-v", f"{companion}:/companion:ro",
                     "-v", f"{temporary / 'server.py'}:/benchmark.py:ro", image, "/benchmark.py"],
                    capture_output=True).stdout.strip()
    try:
        port = run(["docker", "port", container, "8096/tcp"], capture_output=True).stdout.strip().rsplit(":", 1)[1]
        url = "http://127.0.0.1:" + port
        deadline = time.monotonic() + 30
        while True:
            try:
                with urlopen(url + "/one/v1/capabilities", timeout=1):
                    break
            except HTTPError as error:
                if error.code == 401:
                    break
                raise
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The benchmark fixture did not start") from None
                time.sleep(0.1)
        durations = []
        for _ in range(count):
            result = run([str(executable), url], capture_output=True, timeout=30)
            durations.append(json.loads(result.stdout.splitlines()[-1])["seconds"])
            print(f"{label}: {durations[-1]:.3f}s to advancing native playback", flush=True)
            # Release the provider/render slots between cold starts, including when
            # running more trials than the companion's concurrency limit.
            request = Request(url + "/benchmark/reset", method="POST",
                              headers={"Authorization": "Bearer benchmark"})
            with urlopen(request, timeout=10):
                pass
        print(f"{label} median: {statistics.median(durations):.3f}s", flush=True)
        return statistics.median(durations)
    finally:
        subprocess.run(["docker", "rm", "--force", container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="Compare with a local Git commit's encoder and device player")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--image", help="An already built companion server image")
    arguments = parser.parse_args()
    if not 1 <= arguments.runs <= 20:
        parser.error("--runs must be between 1 and 20")
    spec = importlib.util.spec_from_file_location("server_image", ROOT / "scripts/server-image.py")
    server_image = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server_image)
    image = arguments.image or f"music-assistant-one-server:{server_image.music_assistant_version()}"
    run(["swift", "build", "--package-path", "Core"], capture_output=True)
    binary_directory = Path(run(["swift", "build", "--package-path", "Core", "--show-bin-path"], capture_output=True).stdout.strip())
    with tempfile.TemporaryDirectory(prefix="one-playback-") as directory:
        temporary = Path(directory)
        (temporary / "server.py").write_text(SERVER)
        (temporary / "benchmark.swift").write_text(NATIVE)
        baseline = None
        if arguments.baseline_ref:
            revision = run(["git", "rev-parse", "--verify", "--end-of-options", arguments.baseline_ref + "^{commit}"], capture_output=True).stdout.strip()
            companion = temporary / "baseline"
            paths = run(["git", "ls-tree", "-r", "--name-only", revision, "ServerCompanion/music_assistant_one"], capture_output=True).stdout.splitlines()
            for path in paths:
                destination = companion / Path(path).relative_to("ServerCompanion")
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(run(["git", "show", revision + ":" + path], capture_output=True).stdout)
            device = temporary / "BaselineDeviceAudioPlayer.swift"
            device.write_text(run(["git", "show", revision + ":App/Services/DeviceAudioPlayer.swift"], capture_output=True).stdout)
            baseline = measure("baseline", companion, device, temporary, binary_directory, image, arguments.runs)
        current = measure("current", ROOT / "ServerCompanion", ROOT / "App/Services/DeviceAudioPlayer.swift",
                          temporary, binary_directory, image, arguments.runs)
        if baseline:
            print(f"Native cold-start reduction: {(1 - current / baseline) * 100:.1f}%")


if __name__ == "__main__":
    main()

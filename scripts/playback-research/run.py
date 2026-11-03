#!/usr/bin/env python3
"""Real DeviceAudioPlayer + companion regression. No saved account or installed app state.
Run via benchmark-playback.py --reliability --baseline-ref <commit> --output <directory>.
"""
import concurrent.futures
import hashlib
import platform
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('benchmark', ROOT / 'scripts/benchmark-playback.py')
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)
SERVER = benchmark.SERVER.replace('import asyncio', 'import asyncio\nimport time\nimport math\nimport struct')
SERVER = SERVER.replace('    async def source():\n        for _ in range(320):\n            yield bytes(8820)\n            await asyncio.sleep(0.05)', '''    mode, number, _ = uri.split('/')[-1].split('-', 2)
    length = 72 if number == '0' else 12
    chunk = b''.join(struct.pack('<hh', int(2000 * math.sin(2*math.pi*440*i/44100)), int(2000 * math.sin(2*math.pi*440*i/44100))) for i in range(4410))
    async def source():
        anchor = time.monotonic()
        paused = 0
        for index in range(length * 10):
            if mode == 'jitter' and index > 0 and index % 80 == 0:
                await asyncio.sleep(1.5)
                paused += 1.5
            yield chunk
            step = 0.02 if mode == 'fast' else 0.1
            # Deadline pacing includes encoder backpressure and avoids cumulative sleep drift.
            await asyncio.sleep(max(0, anchor + (index + 1) * step + paused - time.monotonic()))''')
SERVER = SERVER.replace("    app.router.add_post('/one/v1/resolve', service.resolve)", "    app.router.add_post('/one/v1/resolve', service.resolve)\n    if hasattr(service, 'prepare_window'):\n        app.router.add_post('/one/v1/prepare', service.prepare_window)")
SNAPSHOT = r'''
    func reliabilitySnapshot() -> [String: Any] {
        let time = player.currentTime().seconds
        return ["status": player.timeControlStatus.rawValue, "time": time.isFinite ? time : -1,
                "position": state.position, "uri": state.current?.media.uri ?? "", "wants": wantsPlayback,
                "buffering": isBuffering, "error": error ?? "",
                "loaded": player.currentItem?.loadedTimeRanges.map { [$0.timeRangeValue.start.seconds, $0.timeRangeValue.end.seconds] } ?? [],
                "reason": player.reasonForWaitingToPlay?.rawValue ?? "",
                "local": (player.currentItem?.asset as? AVURLAsset)?.url.isFileURL ?? false]
    }
'''
NATIVE = r'''
import AVFoundation
import Foundation
import MusicAssistantCore
@main struct Reliability {
    @MainActor static func main() async throws {
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        let address = try ServerAddress(CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let offline = URL(fileURLWithPath: CommandLine.arguments[3])
        let downloads = AudioDownloads(sessionIdentifier: "one.regression." + UUID().uuidString)
        try await downloads.configure(server: address, token: "benchmark")
        let device = DeviceAudioPlayer(downloads: downloads)
        await device.configure(access: IndependentAudioClient(server: address, token: "benchmark"), store: nil)
        device.online = true
        let songs = (0 ..< 3).map { index in
            MediaItem(.object(["uri": .string("fixture://track/\(mode)-\(index)-\(UUID().uuidString)"),
                               "name": .string("Fixture \(index)"), "duration": .number(index == 0 ? 72 : 12)]))
        }
        let start = ProcessInfo.processInfo.systemUptime
        device.insert(songs, option: "replace")
        var advanced = false
        while ProcessInfo.processInfo.systemUptime - start < 125 {
            if FileManager.default.fileExists(atPath: offline.path) { device.online = false }
            var sample = device.reliabilitySnapshot()
            sample["t"] = ProcessInfo.processInfo.systemUptime - start
            sample["cached"] = songs.filter { downloads.isAvailable($0) }.count
            if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
                fflush(stdout)
            }
            if device.state.position > 0.1 { advanced = true }
            if advanced, !device.wantsPlayback { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        device.stop(clear: true)
        await device.flushPersistence()
        try await downloads.erase()
    }
}
'''


def metrics(samples):
    start = next((s['t'] for s in samples if s['position'] > .1 and s['status'] == 2), None)
    waits = []
    first_waits = []
    first_uri = samples[0]["uri"] if samples else ""
    waiting_uri = ""
    forward = 0
    waiting = None
    backwards = 0
    transitions = []
    for previous, sample in zip(samples, samples[1:]):
        if start is None or sample['t'] < start or not sample['wants']:
            continue
        same = sample['uri'] == previous['uri']
        if same and sample['position'] < previous['position'] - .15:
            backwards += 1
        if same and sample['position'] - previous['position'] > sample['t'] - previous['t'] + .75:
            forward += 1
        if not same and sample['position'] > .05:
            transitions.append(sample['t'] - previous['t'])
        stalled = sample['status'] != 2 or sample['buffering']
        if stalled and waiting is None:
            waiting = sample['t']
            waiting_uri = sample['uri']
        if not stalled and waiting is not None:
            waits.append(sample['t'] - waiting)
            if waiting_uri == first_uri:
                first_waits.append(sample['t'] - waiting)
            waiting = None
    # Track changes can first appear at position zero. Measure the gap between the last
    # advancing clock of the first song and the first advancing clock of its successor.
    uris = list(dict.fromkeys(s['uri'] for s in samples if s['position'] > .1))
    gap = None
    if len(uris) > 1:
        last = [s for s in samples if s['uri'] == uris[0] and s['position'] > .1][-1]
        first = next(s for s in samples if s['uri'] == uris[1] and s['position'] > .1)
        gap = max(0, first['t'] - last['t'] - max(0, 72 - last['position']) - first['position'])
    return dict(start_seconds=start, waits=len(waits), wait_seconds=sum(waits), backward_jumps=backwards,
                first_track_waits=len(first_waits), first_track_wait_seconds=sum(first_waits),
                unexpected_forward_jumps=forward, second_track_gap_seconds=gap, advancing_tracks=len(uris),
                offline_local_tracks=len({s['uri'] for s in samples if s['local'] and s['position'] > .1}),
                errors=sorted({s['error'] for s in samples if s['error']}))


def main(arguments):
    output = Path(arguments.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'environment.json').write_text(json.dumps(dict(
        platform=platform.platform(), baseline=arguments.baseline_ref,
        head=benchmark.run(['git', 'rev-parse', 'HEAD'], capture_output=True).stdout.strip(),
        device_sha256=hashlib.sha256((ROOT / 'App/Services/DeviceAudioPlayer.swift').read_bytes()).hexdigest(),
        command=' '.join(__import__('sys').argv)), indent=2) + '\n')
    benchmark.run(['swift', 'build', '--package-path', 'Core'], capture_output=True)
    binary = Path(benchmark.run(['swift', 'build', '--package-path', 'Core', '--show-bin-path'], capture_output=True).stdout.strip())
    aggregate = binary / 'MusicAssistantCore.o'
    objects = [aggregate] if aggregate.exists() else list(binary.glob('MusicAssistantCore.build/*.swift.o'))
    modules = binary if (binary / 'MusicAssistantCore.swiftmodule').exists() else binary / 'Modules'
    with tempfile.TemporaryDirectory(prefix='one-reliability-') as directory:
        temporary = Path(directory)
        (temporary / 'server.py').write_text(SERVER)
        (temporary / 'main.swift').write_text(NATIVE)
        # A command-line player has no app bundle/background-session entitlement. Preserve
        # the real foreground cache, validation and store; omit only explicit-download setup.
        downloads = (ROOT / 'App/Services/AudioDownloads.swift').read_text()
        begin = downloads.index('        session = makeSession()\n        let active = await session.allTasks')
        end = downloads.index('        persistJobs(); resumeQueued()', begin)
        downloads = downloads[:begin] + downloads[end:]
        (temporary / 'AudioDownloads.swift').write_text(downloads)
        versions = [('after', ROOT / 'ServerCompanion', ROOT / 'App/Services/DeviceAudioPlayer.swift')]
        if arguments.baseline_ref:
            revision = benchmark.run(['git', 'rev-parse', '--verify', '--end-of-options', arguments.baseline_ref + '^{commit}'], capture_output=True).stdout.strip()
            companion = temporary / 'baseline'
            for path in benchmark.run(['git', 'ls-tree', '-r', '--name-only', revision, 'ServerCompanion/music_assistant_one'], capture_output=True).stdout.splitlines():
                destination = companion / Path(path).relative_to('ServerCompanion')
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(benchmark.run(['git', 'show', revision + ':' + path], capture_output=True).stdout)
            device = temporary / 'baseline-device.swift'
            device.write_text(benchmark.run(['git', 'show', revision + ':App/Services/DeviceAudioPlayer.swift'], capture_output=True).stdout)
            versions.insert(0, ('before', companion, device))
        for label, _, device in versions:
            instrumented = temporary / (label + '.swift')
            instrumented.write_text(device.read_text().replace('    private func capturePosition() {', SNAPSHOT + '\n    private func capturePosition() {'))
            benchmark.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-I', str(modules), *map(str, objects),
                           'App/Services/CredentialStore.swift', str(temporary / 'AudioDownloads.swift'), str(instrumented),
                           str(temporary / 'main.swift'), '-o', str(temporary / label)], capture_output=True)

        def measure(version, mode, offline=False):
            label, companion, _ = version
            name = label + '-' + ('offline' if offline else mode)
            container = benchmark.run(['docker', 'run', '--rm', '--detach', '--publish', '127.0.0.1::8096', '--entrypoint', 'python',
                                       '-v', f'{companion}:/companion:ro', '-v', f'{temporary / "server.py"}:/benchmark.py:ro',
                                       arguments.image or 'music-assistant-one-server:2.10.9', '/benchmark.py'], capture_output=True).stdout.strip()
            try:
                port = benchmark.run(['docker', 'port', container, '8096/tcp'], capture_output=True).stdout.strip().rsplit(':', 1)[1]
                url = 'http://127.0.0.1:' + port
                for _ in range(200):
                    try:
                        urlopen(url + '/one/v1/capabilities', timeout=1)
                    except benchmark.HTTPError:
                        break
                    except OSError:
                        time.sleep(.1)
                samples = []
                marker = temporary / (name + '-offline')
                with (output / (name + '.jsonl')).open('w') as log, (output / (name + '.stderr')).open('w') as errors:
                    process = subprocess.Popen([str(temporary / label), url, mode, str(marker)], stdout=subprocess.PIPE, stderr=errors, text=True)
                    watchdog = threading.Timer(160, process.kill)
                    watchdog.start()
                    disconnected = False
                    for line in process.stdout:
                        log.write(line)
                        sample = json.loads(line)
                        samples.append(sample)
                        if offline and not disconnected and sample['cached'] == 3:
                            subprocess.run(['docker', 'stop', '--time', '0', container], capture_output=True, check=True)
                            marker.touch()
                            disconnected = True
                    watchdog.cancel()
                    if process.wait(timeout=10):
                        raise RuntimeError(f'{name} failed: see {output / (name + ".stderr")}')
                result = metrics(samples)
                result['signal_loss_seconds'] = next((s['t'] for s in samples if s['cached'] == 3), None) if offline else None
                print(name, json.dumps(result), flush=True)
                return name, result
            finally:
                subprocess.run(['docker', 'rm', '--force', container], capture_output=True)

        jobs = [(version, mode) for version in versions for mode in ('realtime', 'jitter', 'fast')]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(measure, *job) for job in jobs]
            futures.append(pool.submit(measure, versions[-1], 'fast', True))
            results = dict(future.result() for future in futures)
        (output / 'metrics.json').write_text(json.dumps(results, indent=2) + '\n')
        failures = [name for name, result in results.items() if name.startswith('after') and
                    (result['backward_jumps'] or result['unexpected_forward_jumps'] or result['errors'] or result['advancing_tracks'] != 3)]
        if failures:
            raise RuntimeError('Reliability regressions: ' + ', '.join(failures))

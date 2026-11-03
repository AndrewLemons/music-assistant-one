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
SERVER = benchmark.SERVER.replace('import asyncio', 'import asyncio\nimport time\nimport math\nimport struct\nimport random')
SERVER = SERVER.replace('    async def source():\n        for _ in range(320):\n            yield bytes(8820)\n            await asyncio.sleep(0.05)', '''    mode, number, _ = uri.split('/')[-1].split('-', 2)
    length = 600 if mode.startswith('seek') else (72 if number == '0' else 12)
    mode = mode.removeprefix('seek')
    production[uri] = 0
    chunk = b''.join(struct.pack('<hh', int(2000 * math.sin(2*math.pi*440*i/44100)), int(2000 * math.sin(2*math.pi*440*i/44100))) for i in range(4410))
    if uri.split('/')[-1].startswith('seek'):
        # Music-like entropy prevents a tiny repeated tone from fitting minutes in the
        # native byte buffer. Keep the regular reliability fixture exactly unchanged.
        chunk = random.Random(42).randbytes(17640)
    async def source():
        anchor = time.monotonic()
        paused = 0
        for index in range(length * 10):
            if mode == 'jitter' and index > 0 and index % 80 == 0:
                await asyncio.sleep(1.5)
                paused += 1.5
            production[uri] = (index + 1) / 10
            yield chunk
            step = 0.02 if mode == 'fast' else 0.1
            # Deadline pacing includes encoder backpressure and avoids cumulative sleep drift.
            await asyncio.sleep(max(0, anchor + (index + 1) * step + paused - time.monotonic()))''')
SERVER = SERVER.replace("    app.router.add_post('/one/v1/resolve', service.resolve)", "    app.router.add_post('/one/v1/resolve', service.resolve)\n    if hasattr(service, 'prepare_window'):\n        app.router.add_post('/one/v1/prepare', service.prepare_window)")
SERVER = SERVER.replace('async def render(', 'production = {}\nasync def render(')
SERVER = SERVER.replace('    async def reset(request):', '''    async def produced(request):
        await authenticate(request)
        return web.json_response(production)
    app.router.add_get('/benchmark/production', produced)
    async def reset(request):''')
SERVER = SERVER.replace("    app.router.add_get('/one/v1/stream/{ticket}/{file}', service.stream)", '''    async def stream(request):
        ticket = await service.ticket(request.match_info['ticket'])
        # A delayed read ahead of the old playhead must not prevent seeking to other
        # produced segments. Bound loading by a real HTTP delay, not modified player code.
        if '/seek' in ticket.uri and request.match_info['file'] == 'seg20.m4s':
            await asyncio.sleep(180)
        return await service.stream(request)
    app.router.add_get('/one/v1/stream/{ticket}/{file}', stream)''')
SNAPSHOT = r'''
    func reliabilitySnapshot() -> [String: Any] {
        let time = player.currentTime().seconds
        return ["status": player.timeControlStatus.rawValue, "time": time.isFinite ? time : -1,
                "position": state.position, "uri": state.current?.media.uri ?? "", "wants": wantsPlayback,
                "buffering": isBuffering, "error": error ?? "",
                "loaded": player.currentItem?.loadedTimeRanges.map { [$0.timeRangeValue.start.seconds, $0.timeRangeValue.end.seconds] } ?? [],
                "reason": player.reasonForWaitingToPlay?.rawValue ?? "",
                "establishing": establishingPosition,
                "seekable": player.currentItem?.seekableTimeRanges.map { [$0.timeRangeValue.start.seconds, $0.timeRangeValue.end.seconds] } ?? [],
                "automatic_waits": player.automaticallyWaitsToMinimizeStalling,
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
        let seeking = CommandLine.arguments[4] == "seek"
        let local = seeking && mode == "local"
        let sourceMode = local ? "fast" : (seeking ? "seek" + mode : mode)
        let offline = URL(fileURLWithPath: CommandLine.arguments[3])
        let downloads = AudioDownloads(sessionIdentifier: "one.regression." + UUID().uuidString)
        try await downloads.configure(server: address, token: "benchmark")
        let device = DeviceAudioPlayer(downloads: downloads)
        await device.configure(access: IndependentAudioClient(server: address, token: "benchmark"), store: nil)
        device.online = true
        let songs = (0 ..< 3).map { index in
            MediaItem(.object(["uri": .string("fixture://track/\(sourceMode)-\(index)-\(UUID().uuidString)"),
                               "name": .string("Fixture \(index)"), "duration": .number(seeking && !local ? 600 : (index == 0 ? 72 : 12))]))
        }
        // The local control uses the real foreground cache and full-duration validation.
        if local { _ = try await downloads.prepare(songs[0], protecting: [songs[0].uri], format: downloads.streamingFormat) }
        if seeking && !local {
            // Give the source a production lead while it is still growing. Without this,
            // short 1x fixtures load every produced segment and never exercise an unloaded
            // but seekable target. AVFoundation's automatic buffer settings stay unchanged.
            let client = IndependentAudioClient(server: address, token: "benchmark")
            for _ in 0 ..< (mode == "fast" ? 2 : 9) {
                _ = try await client.resolve(songs[0])
                try await Task.sleep(for: .seconds(mode == "fast" ? 3 : 5))
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        func emit(_ fields: [String: Any] = [:]) {
            var sample = device.reliabilitySnapshot()
            sample["t"] = ProcessInfo.processInfo.systemUptime - start
            sample["cached"] = songs.filter { downloads.isAvailable($0) }.count
            for (key, value) in fields { sample[key] = value }
            if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self)); fflush(stdout)
            }
        }
        if seeking {
            device.onChange = { emit(["event": "change"]) }
        }
        device.insert(seeking ? [songs[0]] : songs, option: "replace")
        var seeksDone = false
        let scenario = Task { @MainActor in
            guard seeking else { return }
            defer { seeksDone = true }
            @MainActor func waitUntil(_ predicate: () -> Bool, seconds: Double) async -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + seconds
                while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                return predicate()
            }
            guard await waitUntil({ device.state.position >= 10 && device.reliabilitySnapshot()["status"] as? Int == 2 }, seconds: 30) else {
                emit(["event": "scenario_error", "message": "Initial playback never reached ten seconds"])
                return
            }
            let initialPosition = device.state.position
            var tasks: [Task<Void, Never>] = []
            @MainActor func issue(_ name: String, _ target: Double, superseded: Bool = false) async {
                // Each invocation awaits device.seek just like AppModel.queueCommand; separate
                // main-actor Tasks allow a newer release to supersede the in-flight command.
                let task = Task { @MainActor in
                    emit(["event": "seek", "seek": name, "target": target, "superseded": superseded])
                    await device.seek(target)
                    emit(["event": "seek_return", "seek": name, "target": target])
                }
                tasks.append(task)
                if superseded {
                    try? await Task.sleep(for: .milliseconds(150))
                    return
                }
                // An independent observer, not the returning seek Task, decides success.
                let deadline = ProcessInfo.processInfo.systemUptime + 12
                var anchor: Double?
                var reached = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let sample = device.reliabilitySnapshot()
                    let time = sample["time"] as? Double ?? -1
                    if sample["status"] as? Int == 2, abs(time - target) < 0.5 {
                        if let anchor, time - anchor > 0.05 { reached = true; break }
                        if anchor == nil { anchor = time }
                    }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                emit(["event": reached ? "seek_observed" : "seek_deadline", "seek": name, "target": target])
                // Keep observing for delayed stale callbacks and erroneous resumptions.
                try? await Task.sleep(for: .seconds(1))
            }
            await issue("backward", 3)
            let available = local || mode == "fast" ? 40 : initialPosition + 1
            await issue("forward_available", available)
            if mode == "realtime" {
                let ranges = device.reliabilitySnapshot()["seekable"] as? [[Double]] ?? []
                let edge = ranges.map { $0[1] }.max() ?? 0
                await issue("forward_unbuffered", edge - 6)
            }
            if mode == "realtime" {
                do {
                    var request = URLRequest(url: URL(string: CommandLine.arguments[1] + "/benchmark/production")!)
                    request.setValue("Bearer benchmark", forHTTPHeaderField: "Authorization")
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let produced = try JSONDecoder().decode([String: Double].self, from: data)[songs[0].uri] ?? 0
                    emit(["event": "production", "produced": produced])
                    await issue("forward_future", produced + 3)
                } catch {
                    emit(["event": "scenario_error", "message": error.localizedDescription])
                }
            }
            for (index, target) in [8.0, 4, 9, 6, 5].enumerated() {
                await issue("burst_\(index + 1)", target, superseded: index < 4)
            }
            for task in tasks { task.cancel() }
        }
        var advanced = false
        while ProcessInfo.processInfo.systemUptime - start < 125 {
            if FileManager.default.fileExists(atPath: offline.path) { device.online = false }
            emit(["event": "sample"])
            if seeking && seeksDone { break }
            if device.state.position > 0.1 { advanced = true }
            if !seeking, advanced, !device.wantsPlayback { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        scenario.cancel()
        device.onChange = nil
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
    native_gap = None
    if len(uris) > 1:
        last = [s for s in samples if s['uri'] == uris[0] and s['position'] > .1][-1]
        first = next(s for s in samples if s['uri'] == uris[1] and s['position'] > .1)
        gap = max(0, first['t'] - last['t'] - max(0, 72 - last['position']) - first['position'])
        # Exposed positions update every 500 ms. Their phase at the track boundary can
        # hide or inflate a short gap even with 100 ms sampling. Preserve the old metric
        # for comparison, and also extrapolate from the advancing native clock directly.
        last = [s for s in samples if s['uri'] == uris[0] and s['status'] == 2 and s['time'] > .1][-1]
        first = next(s for s in samples if s['uri'] == uris[1] and s['status'] == 2 and s['time'] > .1)
        native_gap = max(0, first['t'] - last['t'] - max(0, 72 - last['time']) - first['time'])
    return dict(start_seconds=start, waits=len(waits), wait_seconds=sum(waits), backward_jumps=backwards,
                first_track_waits=len(first_waits), first_track_wait_seconds=sum(first_waits),
                unexpected_forward_jumps=forward, second_track_gap_seconds=gap, advancing_tracks=len(uris),
                native_second_track_gap_seconds=native_gap,
                offline_local_tracks=len({s['uri'] for s in samples if s['local'] and s['position'] > .1}),
                errors=sorted({s['error'] for s in samples if s['error']}))


def seek_metrics(samples):
    """Exclude intentional moves, but never excuse a stale exposed clock or audible move.

    A seek passes only after two 100 ms observations show native-clock advancement
    near the target AND the exposed position agrees. Returning from seek is not proof.
    onChange observations catch exposed-position glitches between periodic samples;
    audible proxies use periodic samples so synchronous pause/seek setup isn't counted.
    """
    issues = [i for i, sample in enumerate(samples) if sample.get('event') == 'seek']
    seeks = []
    for index, begin in enumerate(issues):
        issue = samples[begin]
        end = issues[index + 1] if index + 1 < len(issues) else len(samples)
        window = samples[begin + 1:end]
        target = issue['target']
        anchor = None
        reached = None
        for sample in window:
            if sample.get('event') != 'sample':
                continue
            if (sample['status'] == 2 and abs(sample['time'] - target) < .5
                    and abs(sample['position'] - target) < .5):
                if anchor is not None and sample['time'] - anchor['time'] > .05:
                    reached = sample
                    break
                if anchor is None:
                    anchor = sample
        # Once native playback starts at the target, its expected clock advances at 1x.
        # Until then the exposed clock must stay at the requested position, even when
        # AVFoundation's paused playhead still points at the previous location.
        position_away = []
        audible_away = []
        for sample in window:
            if sample.get('event') not in ('sample', 'change'):
                continue
            elapsed = max(0, sample['t'] - anchor['t']) if anchor else 0
            expected = (anchor['time'] + elapsed) if anchor and sample['t'] >= anchor['t'] else target
            if abs(sample['position'] - expected) > .65:
                position_away.append(sample)
            if sample.get('event') == 'sample' and sample['status'] == 2 and abs(sample['time'] - expected) > .5:
                audible_away.append(sample)
        superseded = issue['superseded']
        latency = reached['t'] - issue['t'] if reached else None
        local = issue['local']
        deadline = 12 if issue['seek'] == 'forward_future' else (2.5 if local or '/seekfast-' in issue['uri'] else 6.5)
        seekable_end = max((r[1] for r in issue['seekable']), default=0)
        seeks.append(dict(
            name=issue['seek'], target=target, issued_seconds=issue['t'], local=local,
            seekable_end_at_issue=seekable_end, loaded_at_issue=issue['loaded'],
            latency_seconds=latency, superseded=superseded, deadline_seconds=deadline,
            observation_timed_out=any(s.get('event') == 'seek_deadline' for s in window),
            position_away_samples=len(position_away), audible_away_samples=len(audible_away),
            backward_position_jumps=sum(s['position'] < target for s in position_away),
            forward_position_jumps=sum(s['position'] >= target for s in position_away),
            first_position_away=position_away[0] if position_away else None,
            passed=not position_away and not audible_away and (superseded or latency is not None and latency <= deadline)))
    errors = sorted({s['error'] for s in samples if s['error']} |
                    {s['message'] for s in samples if s.get('event') == 'scenario_error'})
    expected = ['backward', 'forward_available']
    if samples and '/seekrealtime-' in samples[-1]['uri']:
        expected += ['forward_unbuffered', 'forward_future']
    expected += [f'burst_{i}' for i in range(1, 6)]
    automatic_waits = all(s['automatic_waits'] for s in samples)
    preconditions = all(s['local'] or s['target'] <= s['seekable_end_at_issue'] - .5
                        for s in seeks if s['name'] == 'forward_available')
    unbuffered = [s for s in seeks if s['name'] == 'forward_unbuffered']
    if samples and '/seekfast-' in samples[-1]['uri']:
        unbuffered += [s for s in seeks if s['name'] == 'forward_available']
    preconditions = preconditions and all(s['target'] > max((r[1] for r in s['loaded_at_issue']), default=0) + .5
                                            and s['target'] < s['seekable_end_at_issue'] - .5 for s in unbuffered)
    production = next((s['produced'] for s in samples if s.get('event') == 'production'), None)
    future = next((s for s in seeks if s['name'] == 'forward_future'), None)
    if future:
        preconditions = preconditions and production is not None and future['target'] > production
    return dict(start_seconds=metrics(samples)['start_seconds'], seeks=seeks, errors=errors,
                produced_before_future=production, preconditions_met=preconditions,
                automatic_waits=automatic_waits,
                passed=bool(seeks) and [s['name'] for s in seeks] == expected and preconditions
                and automatic_waits and not errors and all(s['passed'] for s in seeks))


def main(arguments):
    output = Path(arguments.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'environment.json').write_text(json.dumps(dict(
        platform=platform.platform(), baseline=arguments.baseline_ref,
        head=benchmark.run(['git', 'rev-parse', 'HEAD'], capture_output=True).stdout.strip(),
        device_sha256=hashlib.sha256((ROOT / 'App/Services/DeviceAudioPlayer.swift').read_bytes()).hexdigest(),
        command=' '.join(__import__('sys').argv)), indent=2) + '\n')
    with tempfile.TemporaryDirectory(prefix='one-reliability-') as directory:
        temporary = Path(directory)
        build = ['swift', 'build', '--package-path', 'Core', '--scratch-path', str(temporary / 'build')]
        benchmark.run(build, capture_output=True)
        binary = Path(benchmark.run([*build, '--show-bin-path'], capture_output=True).stdout.strip())
        aggregate = binary / 'MusicAssistantCore.o'
        objects = [aggregate] if aggregate.exists() else list(binary.glob('MusicAssistantCore.build/*.swift.o'))
        modules = binary if (binary / 'MusicAssistantCore.swiftmodule').exists() else binary / 'Modules'
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
            name = label + '-' + ('offline' if offline else ('seek-' + mode if arguments.seek else mode))
            container = benchmark.run(['docker', 'run', '--rm', '--pull', 'never', '--detach', '--label', 'one.playback-research=true', '--publish', '127.0.0.1::8096', '--entrypoint', 'python',
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
                with (output / (name + '.jsonl')).open('w', buffering=1) as log, (output / (name + '.stderr')).open('w') as errors:
                    process = subprocess.Popen([str(temporary / label), url, mode, str(marker), 'seek' if arguments.seek else 'queue'], stdout=subprocess.PIPE, stderr=errors, text=True)
                    watchdog = threading.Timer(240, process.kill)
                    watchdog.start()
                    disconnected = False
                    try:
                        for line in process.stdout:
                            log.write(line)
                            sample = json.loads(line)
                            samples.append(sample)
                            if offline and not disconnected and sample['cached'] == 3:
                                subprocess.run(['docker', 'stop', '--time', '0', container], capture_output=True, check=True)
                                marker.touch()
                                disconnected = True
                        if process.wait(timeout=10):
                            raise RuntimeError(f'{name} failed: see {output / (name + ".stderr")}')
                    finally:
                        watchdog.cancel()
                        if process.poll() is None:
                            process.kill()
                        process.wait()
                        process.stdout.close()
                result = seek_metrics(samples) if arguments.seek else metrics(samples)
                result['signal_loss_seconds'] = next((s['t'] for s in samples if s['cached'] == 3), None) if offline else None
                summary = ({'passed': result['passed'], 'preconditions_met': result['preconditions_met'],
                            'seeks': {s['name']: s['latency_seconds'] for s in result['seeks']},
                            'position_away_samples': sum(s['position_away_samples'] for s in result['seeks']),
                            'audible_away_samples': sum(s['audible_away_samples'] for s in result['seeks']),
                            'errors': result['errors']} if arguments.seek else result)
                print(name, json.dumps(summary), flush=True)
                return name, result
            finally:
                subprocess.run(['docker', 'rm', '--force', container], capture_output=True)

        modes = ('realtime', 'fast', 'local') if arguments.seek else ('realtime', 'jitter', 'fast')
        jobs = [(version, mode) for version in versions for mode in modes]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(measure, *job) for job in jobs]
            if not arguments.seek:
                futures.append(pool.submit(measure, versions[-1], 'fast', True))
            results = dict(future.result() for future in futures)
        (output / 'metrics.json').write_text(json.dumps(results, indent=2) + '\n')
        if arguments.seek:
            failures = [name for name, result in results.items() if name.startswith('after') and not result['passed']]
        else:
            failures = [name for name, result in results.items() if name.startswith('after') and
                        (result['backward_jumps'] or result['unexpected_forward_jumps'] or result['errors'] or result['advancing_tracks'] != 3)]
        if failures:
            raise RuntimeError('Reliability regressions: ' + ', '.join(failures))

import AVFoundation

/// The left-channel chirp f(t) = 200 + 10t Hz identifies the decoded position independently
/// of AVPlayer's clock. The other channel changes entropy halfway through the song.
private final class Tap {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate = 0.0
    private var supported = false

    func prepare(_ format: AudioStreamBasicDescription) {
        lock.withLock {
            rate = format.mSampleRate
            supported = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
                format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && format.mBitsPerChannel == 32
        }
    }

    func append(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        lock.withLock {
            guard supported else { return }
            let buffer = UnsafeMutableAudioBufferListPointer(buffers)[0]
            guard let data = buffer.mData else { return }
            let count = min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            samples.append(contentsOf: UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: count
            ))
        }
    }

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }

    func measurement() -> (count: Int, position: Double?) {
        lock.withLock {
            let window = Array(samples.suffix(Int(rate / 10)))
            guard supported, rate > 0, window.count >= Int(rate / 10),
                  window.contains(where: { abs($0) > 0.01 }) else { return (samples.count, nil) }
            let crossings = (1 ..< window.count).filter { (window[$0 - 1] < 0) != (window[$0] < 0) }.count
            let frequency = Double(crossings) / 2 / (Double(window.count) / rate)
            return (samples.count, (frequency - 200) / 10)
        }
    }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let item = AVPlayerItem(url: url)
        let state = Tap()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(state).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: nil,
            prepare: { tap, _, format in
                Unmanaged<Tap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr
                else { return }
                Unmanaged<Tap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().append(
                    buffers,
                    frames: framesOut.pointee
                )
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        ) == noErr else {
            throw NSError(domain: "AudibleSeek", code: 2)
        }
        let track = try await item.asset.loadTracks(withMediaType: .audio)[0]
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        player.volume = 0 // The tap measures decoded audio before the output volume.
        let deadline = ContinuousClock.now + .seconds(10)
        while item.status != .readyToPlay {
            guard item.status != .failed, ContinuousClock.now < deadline else {
                throw item.error ?? NSError(domain: "AudibleSeek", code: 3)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        var passed = true
        for target in [30.0, 90.0, 150.0, 200.0, 230.0] {
            let sought = await player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            state.reset()
            player.play()
            try await Task.sleep(for: .milliseconds(600))
            player.pause()
            let reported = player.currentTime().seconds
            let measurement = state.measurement()
            let accurate = sought && measurement.position
                .map { abs($0 - reported) <= 1 && abs($0 - target) <= 1.5 } == true
            passed = passed && accurate
            let row: [String: Any] = [
                "target": target, "reported": reported, "audible": measurement.position as Any? ?? NSNull(),
                "error_seconds": measurement.position.map { $0 - reported } as Any? ?? NSNull(),
                "samples": measurement.count, "passed": accurate,
            ]
            try print(String(
                decoding: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                as: UTF8.self
            ))
        }
        player.replaceCurrentItem(with: nil)
        withExtendedLifetime(state) {}
        exit(passed ? 0 : 1)
    }
}

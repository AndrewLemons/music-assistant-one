import AVFoundation

/// Seeks a real AVPlayer and measures what is audible through an audio tap. The left channel
/// is a chirp, f(t) = 200 + 10 t Hz, so its frequency reveals the true playback position.
final class Tap {
    var samples: [Float] = []
    let lock = NSLock()
}

@main struct Probe {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let item = AVPlayerItem(url: url)
        let tapState = Tap()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(tapState).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: nil,
            prepare: { _, _, format in
                let f = format.pointee
                print("tap format: rate=\(f.mSampleRate) flags=\(f.mFormatFlags) bits=\(f.mBitsPerChannel) ch=\(f.mChannelsPerFrame) bpf=\(f.mBytesPerFrame)")
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
                let state = Unmanaged<Tap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                guard let data = list[0].mData else { return }
                let count = Int(list[0].mDataByteSize) / 4
                let floats = data.bindMemory(to: Float.self, capacity: count)
                // Non-interleaved: buffer 0 is the left channel.
                state.lock.lock(); state.samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count)); state.lock.unlock()
            }
        )
        var tap: MTAudioProcessingTap?
        MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        let track = try await item.asset.loadTracks(withMediaType: .audio)[0]
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        while item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(50)) }
        for target in [30.0, 90.0, 150.0, 200.0, 230.0] {
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            tapState.lock.lock(); tapState.samples.removeAll(); tapState.lock.unlock()
            player.play()
            try await Task.sleep(for: .milliseconds(600))
            player.pause()
            let reported = player.currentTime().seconds
            tapState.lock.lock(); let all = tapState.samples; tapState.lock.unlock()
            print("captured \(all.count) samples, range \(all.min() ?? 0)...\(all.max() ?? 0)")
            tapState.lock.lock(); let window = Array(tapState.samples.suffix(4410)); tapState.lock.unlock()
            var crossings = 0
            for i in 1 ..< max(1, window.count) where (window[i - 1] < 0) != (window[i] < 0) { crossings += 1 }
            let frequency = Double(crossings) / 2 / (Double(max(1, window.count)) / 44100)
            let audible = (frequency - 200) / 10
            print(String(format: "requested %6.1f  reported-now %6.1f  audible-now %6.1f  error %+6.1f s",
                         target, reported, audible, audible - reported))
        }
    }
}

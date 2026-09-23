import AppKit
import MediaPlayer

// Transfers a fully initialized artwork object to MediaPlayer's caller queue.
// This test never mutates it after construction.
private struct ArtworkBox: @unchecked Sendable {
    let value: MPMediaItemArtwork
}

@main struct ArtworkRegression {
    @MainActor static func main() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        guard let artwork = SystemMediaArtwork.make(data: data) else { fatalError("Valid image was rejected") }
        precondition(SystemMediaArtwork.make(data: Data("invalid image".utf8)) == nil)
        let box = ArtworkBox(value: artwork)
        // A main-actor-inherited provider traps here, matching the playback crash.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                precondition(!Thread.isMainThread)
                for _ in 0..<64 {
                    guard let image = box.value.image(at: CGSize(width: 16, height: 16)) else {
                        fatalError("Background artwork request failed")
                    }
                    precondition(image.size.width > 0 && image.size.height > 0)
                }
                continuation.resume()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Artwork regression fixture",
            MPMediaItemPropertyArtwork: artwork
        ]
        try await Task.sleep(for: .seconds(2))
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        print("PASS: background artwork requests and system Now Playing publication")
    }
}

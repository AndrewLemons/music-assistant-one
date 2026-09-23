import Foundation
import MediaPlayer
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum SystemMediaArtwork {
    /// MediaPlayer calls the synchronous provider on its own queue. Keep its
    /// construction outside MainActor so the closure never inherits UI isolation.
    nonisolated static func make(data: Data) -> MPMediaItemArtwork? {
        #if os(macOS)
            guard let image = NSImage(data: data) else { return nil }
        #else
            guard let image = UIImage(data: data) else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

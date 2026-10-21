import Foundation
import ImageIO
import SwiftUI
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Decoded artwork stays in memory, and server thumbnails stay in a disk cache, so
/// scrolling and returning to a page show artwork immediately. Images are decoded at
/// the size they are displayed, off the main thread.
@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()
    private let memory = NSCache<NSString, CGImage>()
    private var loading: [String: Task<CGImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private init() {
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    private static func key(_ url: URL, _ pixels: Int) -> String {
        "\(pixels)|\(url.absoluteString)"
    }

    func cached(_ url: URL, pixels: Int) -> CGImage? {
        memory.object(forKey: Self.key(url, pixels) as NSString)
    }

    func image(_ url: URL, pixels: Int) async -> CGImage? {
        let key = Self.key(url, pixels)
        if let image = memory.object(forKey: key as NSString) {
            return image
        }
        if let task = loading[key] {
            return await task.value
        }
        let task = Task { [session] () -> CGImage? in
            // Transient failures retry once; cancelled views leave the shared request running.
            for attempt in 0 ..< 2 {
                let data: Data? = if url.isFileURL {
                    try? await Task.detached { try Data(contentsOf: url) }.value
                } else {
                    try? await session.data(from: url).0
                }
                if let data, let image = await Task.detached(operation: { Self.decode(data, pixels: pixels) }).value {
                    return image
                }
                if url.isFileURL || attempt == 1 {
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return nil
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private nonisolated static func decode(_ data: Data, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, pixels),
        ] as CFDictionary)
    }
}

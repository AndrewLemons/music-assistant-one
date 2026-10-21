import CryptoKit
import Foundation

public struct StoredAudio: Codable, Sendable, Identifiable, Equatable {
    public var id: String {
        MediaItem(metadata).uri
    }

    public let metadata: JSONValue
    public let filename: String
    public var downloaded: Bool
    public let bytes: Int64
    public var lastAccess: Date
    public var media: MediaItem {
        MediaItem(metadata)
    }
}

public struct SavedCollection: Codable, Sendable, Equatable {
    public let metadata: JSONValue
    public let tracks: [JSONValue]
    public init(item: MediaItem, tracks: [MediaItem]) {
        metadata = item.offlineMetadata
        self.tracks = tracks.map(\.offlineMetadata)
    }
}

/// Serializes manifest/file changes. Downloaded audio is never evicted by cache cleanup.
public actor AudioFileStore {
    private struct Manifest: Codable {
        var version = 1
        var audio: [StoredAudio] = []
        var collections: [SavedCollection] = []
        var queue = DevicePlaybackQueue()
    }

    public let directory: URL
    public let cacheDirectory: URL
    private var manifest = Manifest()
    private let manifestURL: URL
    public static let defaultCacheLimit: Int64 = 512 * 1024 * 1024

    public static func scope(server: ServerAddress, account: String) -> String {
        SHA256.hash(data: Data((server.baseURL.absoluteString + "\n" + account).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public init(directory: URL, cacheDirectory: URL) throws {
        self.directory = directory
        self.cacheDirectory = cacheDirectory
        manifestURL = directory.appendingPathComponent("library.json")
        for var folder in [directory, cacheDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        }
        // A purged cache or deleted file must never appear as available offline.
        manifest.audio.removeAll { record in
            let root = record.downloaded ? directory : cacheDirectory
            return !FileManager.default.fileExists(atPath: root.appendingPathComponent(record.filename).path)
        }
    }

    public func records() -> [StoredAudio] {
        manifest.audio
    }

    public func collections() -> [SavedCollection] {
        manifest.collections
    }

    public func queue() -> DevicePlaybackQueue {
        manifest.queue
    }

    public func saveQueue(_ queue: DevicePlaybackQueue) throws {
        manifest.queue = queue
        try save()
    }

    public func saveCollection(_ collection: SavedCollection) throws {
        manifest.collections.removeAll { $0.metadata["uri"] == collection.metadata["uri"] }
        manifest.collections.append(collection)
        try save()
    }

    public func file(for uri: String) throws -> URL? {
        guard let index = manifest.audio.firstIndex(where: { $0.id == uri }) else { return nil }
        let record = manifest.audio[index]
        let url = location(record)
        guard FileManager.default.fileExists(atPath: url.path) else {
            manifest.audio.remove(at: index); try save(); return nil
        }
        manifest.audio[index].lastAccess = .now
        return url
    }

    /// The caller validates the HTTP response and audio before committing a complete temporary file.
    @discardableResult public func commit(_ temporary: URL, media: MediaItem, downloaded: Bool) throws -> StoredAudio {
        let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw MAError.message("The server returned an empty audio file.") }
        let old = manifest
        let existing = manifest.audio.first { $0.id == media.uri }
        let pinned = downloaded || existing?.downloaded == true
        let filename = UUID().uuidString + ".flac"
        let destination = (pinned ? directory : cacheDirectory).appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let record = StoredAudio(
            metadata: media.offlineMetadata,
            filename: filename,
            downloaded: pinned,
            bytes: Int64(bytes),
            lastAccess: .now
        )
        manifest.audio.removeAll { $0.id == media.uri }; manifest.audio.append(record)
        do { try save() } catch {
            manifest = old; try? FileManager.default.removeItem(at: destination); throw error
        }
        if let existing {
            try? FileManager.default.removeItem(at: location(existing))
        }
        return record
    }

    public func keepDownload(_ uri: String) throws {
        guard let index = manifest.audio.firstIndex(where: { $0.id == uri }),
              !manifest.audio[index].downloaded else { return }
        let old = manifest.audio[index]
        let destination = directory.appendingPathComponent(old.filename)
        try FileManager.default.copyItem(at: location(old), to: destination)
        manifest.audio[index].downloaded = true
        do { try save() } catch {
            manifest.audio[index] = old; try? FileManager.default.removeItem(at: destination); throw error
        }
        try? FileManager.default.removeItem(at: location(old))
    }

    public func remove(_ uri: String) throws {
        guard let record = manifest.audio.first(where: { $0.id == uri }) else { return }
        manifest.audio.removeAll { $0.id == uri }
        do { try save() } catch { manifest.audio.append(record); throw error }
        try FileManager.default.removeItem(at: location(record))
    }

    public func trimCache(limit: Int64 = defaultCacheLimit, protecting uris: Set<String> = []) throws {
        let cached = manifest.audio.filter { !$0.downloaded }.sorted { $0.lastAccess < $1.lastAccess }
        var bytes = cached.reduce(Int64(0)) { $0 + $1.bytes }
        for record in cached where bytes > limit && !uris.contains(record.id) {
            try remove(record.id); bytes -= record.bytes
        }
    }

    private func location(_ record: StoredAudio) -> URL {
        (record.downloaded ? directory : cacheDirectory).appendingPathComponent(record.filename)
    }

    private func save() throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }
}

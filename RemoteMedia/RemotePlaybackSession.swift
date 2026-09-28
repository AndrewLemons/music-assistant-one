import Foundation
import ImageIO
import MusicAssistantCore
import NowPlaying
import Observation
import OSLog
import UniformTypeIdentifiers

protocol RemotePlaybackAPI: Sendable {
    var events: AsyncStream<JSONValue> { get }
    func connect(server: ServerAddress, token: String) async throws -> JSONValue
    func command(_ name: String, args: [String: JSONValue]) async throws -> JSONValue
    func disconnect() async
}

extension MusicAssistantClient: RemotePlaybackAPI {}

/// Lives in the system's extension process, so commands work when the app is suspended.
@MainActor @Observable
final class RemotePlaybackSession: RemoteMediaSessionRepresentable {
    let id: String
    private(set) var attributes: RemotePlaybackAttributes
    private let api: any RemotePlaybackAPI
    private let readToken: (ServerAddress) throws -> String?
    private var connected = false
    private var connectionTask: Task<Void, any Error>?
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artworkData: Data?
    private let fetchArtwork: @Sendable (URL) async throws -> Data

    init(
        attributes: RemotePlaybackAttributes,
        api: any RemotePlaybackAPI = MusicAssistantClient(),
        readToken: @escaping (ServerAddress) throws -> String? = CredentialStore.token,
        fetchArtwork: @escaping @Sendable (URL) async throws -> Data = RemoteArtwork.fetch
    ) {
        self.api = api
        self.readToken = readToken
        self.fetchArtwork = fetchArtwork
        id = attributes.id
        self.attributes = attributes
        eventTask = Task { [weak self, api] in
            for await event in api.events {
                guard let self else { return }
                let name = event["event"].string ?? ""
                if name == "connection_lost" {
                    connected = false
                }
                if name.hasPrefix("queue_") || name.hasPrefix("player_") {
                    scheduleRefresh()
                }
            }
        }
        // The initial attributes render immediately; fetch fresh state when the extension wakes.
        scheduleRefresh()
        loadArtwork()
    }

    func update(_ attributes: RemotePlaybackAttributes) {
        guard attributes.id == id, attributes.timestamp >= self.attributes.timestamp else { return }
        self.attributes = attributes
        loadArtwork()
    }

    private var queue: PlayerQueue {
        PlayerQueue(attributes.queue)
    }

    var content: (any MediaContentRepresentable)? {
        guard let item = queue.current else { return nil }
        let artwork: Artwork? = if let artworkData, let artworkURL {
            Artwork(id: artworkURL.absoluteString) { @Sendable size in
                try RemoteArtwork.representation(data: artworkData, size: size)
            }
        } else {
            nil
        }
        return GenericContent(
            id: item.id,
            title: item.name,
            subtitle: item.subtitle,
            type: .audio,
            duration: queue.duration > 0 ? .finite(queue.duration) : .live,
            artwork: artwork
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        let now = Date.now
        let state: MediaPlaybackSnapshot.PlaybackState = queue.current == nil || queue.raw["ended"].bool == true
            ? .stopped : queue.isPlaying ? .playing(rate: Float(queue.raw["playback_speed"].double ?? 1)) : .paused
        return MediaPlaybackSnapshot(
            state: state,
            elapsedTime: queue.elapsed(at: now),
            timestamp: now
        )
    }

    var devices: [MediaDevice] {
        [MediaDevice(id: attributes.playerID, name: attributes.playerName, type: .speaker, capabilities: [])]
    }

    var commands: [MediaCommand] {
        [
            .play { try await self.playback("play") },
            .pause { try await self.playback("pause") },
            .togglePlayPause {
                try await self.refresh()
                try await self.playback(self.queue.isPlaying ? "pause" : "play")
            },
            .next { try await self.playback("next") },
            .previous { try await self.playback("previous") },
            .seekToPosition { try await self.seek(to: $0) }.enabled(queue.duration > 0),
        ]
    }

    private func connect() async throws {
        if let connectionTask {
            return try await connectionTask.value
        }
        guard !connected else { return }
        let server = try ServerAddress(attributes.serverURL.absoluteString)
        guard let token = try readToken(server) else {
            throw MAError.message("Open Music Assistant One and sign in to control playback.")
        }
        let task = Task { [api] in _ = try await api.connect(server: server, token: token) }
        connectionTask = task
        defer { connectionTask = nil }
        try await task.value
        connected = true
    }

    func playback(_ command: String) async throws {
        try await connect()
        _ = try await api.command("players/cmd/\(command)", args: ["player_id": .string(attributes.playerID)])
        try await refresh()
    }

    func seek(to position: Double) async throws {
        try await refresh()
        guard position.isFinite, position >= 0, queue.duration > 0 else {
            throw MAError.message("This item does not support seeking.")
        }
        _ = try await api.command("player_queues/seek", args: [
            "queue_id": .string(queue.id),
            "position": .number(min(position, queue.duration).rounded()),
        ])
        try await refresh()
    }

    private func refresh() async throws {
        try await connect()
        let result = try await api.command(
            "player_queues/get_active_queue",
            args: ["player_id": .string(attributes.playerID)]
        )
        attributes.updateQueue(PlayerQueue(result))
        loadArtwork()
    }

    private func loadArtwork() {
        let server = try? ServerAddress(attributes.serverURL.absoluteString)
        let url = queue.current?.artworkURL(server: server)
        guard url != artworkURL || (artworkData == nil && artworkTask == nil) else { return }
        artworkTask?.cancel()
        artworkURL = url
        artworkData = nil
        guard let url else { artworkTask = nil; return }
        // Publish artwork only after fetching and validating it. A transient network failure
        // must not poison NowPlaying's cache for an otherwise stable artwork identifier.
        artworkTask = Task { [weak self, fetchArtwork] in
            for attempt in 0 ..< 3 {
                do {
                    if attempt > 0 {
                        try await Task.sleep(for: .seconds(attempt))
                    }
                    let data = try await fetchArtwork(url)
                    _ = try RemoteArtwork.representation(data: data, size: CGSize(width: 512, height: 512))
                    try Task.checkCancellation()
                    guard let self, artworkURL == url else { return }
                    artworkData = data
                    artworkTask = nil
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if attempt == 2 {
                        Logger(subsystem: "com.lemonyclick.music-assistant-one", category: "RemoteArtwork")
                            .error(
                                "Unable to load remote artwork: \(String(describing: type(of: error)), privacy: .public)"
                            )
                    }
                }
            }
            self?.artworkTask = nil
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await self?.refresh()
            } catch { /* A command retries the connection and reports errors to the system. */ }
            self?.refreshTask = nil
        }
    }

    isolated deinit {
        artworkTask?.cancel()
        eventTask?.cancel()
        refreshTask?.cancel()
        connectionTask?.cancel()
        Task { [api] in await api.disconnect() }
    }
}

enum RemoteArtwork {
    nonisolated static func representation(data: Data, size: CGSize) throws -> ArtworkRepresentation {
        // Normalize to JPEG for NowPlaying compatibility, after resolving queue artwork
        // and fetching it successfully. Conversion alone cannot repair missing metadata.
        let requestedSize = max(size.width, size.height)
        let pixelSize = requestedSize.isFinite && requestedSize > 0 ? min(requestedSize, 2048) : 1024
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixelSize,
              ] as CFDictionary)
        else {
            throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
        }
        return try ArtworkRepresentation(data: encoded as Data)
    }

    nonisolated static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

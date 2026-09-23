import Foundation
import MusicAssistantCore
import NowPlaying
import Observation

protocol RemotePlaybackAPI: Sendable {
    var events: AsyncStream<JSONValue> { get }
    func connect(server: ServerAddress, token: String) async throws -> JSONValue
    func command(_ name: String, args: [String: JSONValue]) async throws -> JSONValue
    func disconnect() async
}

extension MusicAssistantClient: RemotePlaybackAPI { }

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

    init(attributes: RemotePlaybackAttributes, api: any RemotePlaybackAPI = MusicAssistantClient(),
         readToken: @escaping (ServerAddress) throws -> String? = CredentialStore.token) {
        self.api = api
        self.readToken = readToken
        id = attributes.id
        self.attributes = attributes
        eventTask = Task { [weak self, api] in
            for await event in api.events {
                guard let self else { return }
                let name = event["event"].string ?? ""
                if name == "connection_lost" { self.connected = false }
                if name.hasPrefix("queue_") || name.hasPrefix("player_") { self.scheduleRefresh() }
            }
        }
        // The initial attributes render immediately; fetch fresh state when the extension wakes.
        scheduleRefresh()
    }

    func update(_ attributes: RemotePlaybackAttributes) {
        guard attributes.id == id, attributes.timestamp >= self.attributes.timestamp else { return }
        self.attributes = attributes
    }

    private var queue: PlayerQueue { PlayerQueue(attributes.queue) }

    var content: (any MediaContentRepresentable)? {
        guard let item = queue.current else { return nil }
        let server = try? ServerAddress(attributes.serverURL.absoluteString)
        let artwork = item.artworkURL(server: server).map { url in
            Artwork(id: url.absoluteString) { @Sendable _ in
                let (data, _) = try await URLSession.shared.data(from: url)
                return try ArtworkRepresentation(data: data)
            }
        }
        return GenericContent(id: item.id, title: item.name, subtitle: item.subtitle,
                              type: .audio, duration: queue.duration > 0 ? .finite(queue.duration) : .live,
                              artwork: artwork)
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        let now = Date.now
        let state: MediaPlaybackSnapshot.PlaybackState = queue.current == nil || queue.raw["ended"].bool == true
            ? .stopped : queue.isPlaying ? .playing(rate: Float(queue.raw["playback_speed"].double ?? 1)) : .paused
        return MediaPlaybackSnapshot(state: state,
                                     elapsedTime: queue.elapsed(at: now), timestamp: now)
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
            .seekToPosition { try await self.seek(to: $0) }.enabled(queue.duration > 0)
        ]
    }

    private func connect() async throws {
        if let connectionTask { return try await connectionTask.value }
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
            "position": .number(min(position, queue.duration).rounded())
        ])
        try await refresh()
    }

    private func refresh() async throws {
        try await connect()
        let result = try await api.command("player_queues/get_active_queue", args: ["player_id": .string(attributes.playerID)])
        attributes.updateQueue(PlayerQueue(result))
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
        eventTask?.cancel()
        refreshTask?.cancel()
        connectionTask?.cancel()
        Task { [api] in await api.disconnect() }
    }
}

#if os(iOS)
import Foundation
import MusicAssistantCore
import NowPlaying

/// Public playback metadata only. Credentials stay in the shared Keychain.
@available(iOS 27, *)
struct RemotePlaybackAttributes: RemoteMediaSessionAttributes, Sendable {
    let id: String
    let serverURL: URL
    let playerID: String
    let playerName: String
    var queue: JSONValue
    var timestamp: Date

    init(server: ServerAddress, player: Player, queue: PlayerQueue, timestamp: Date = .now) {
        id = server.baseURL.absoluteString + "|" + player.id
        serverURL = server.baseURL
        playerID = player.id
        playerName = player.name
        self.queue = .null
        self.timestamp = timestamp
        updateQueue(queue, at: timestamp)
    }

    mutating func updateQueue(_ queue: PlayerQueue, at date: Date = .now) {
        let server = try? ServerAddress(serverURL.absoluteString)
        let item: JSONValue = queue.current.map { media in
            var value: [String: JSONValue] = [
                "uri": .string(media.id), "name": .string(media.name),
                "artists": .array([.object(["name": .string(media.subtitle)])]),
                "duration": .number(queue.duration)
            ]
            if let url = media.artworkURL(server: server) {
                value["image"] = .object(["path": .string(url.absoluteString)])
            }
            return .object(value)
        } ?? .null
        // Whitelist display fields: stream details and provider-specific data never
        // leave the app/server connection through the system's session attributes.
        self.queue = .object([
            "queue_id": .string(queue.id), "state": queue.raw["state"],
            "elapsed_time": .number(queue.elapsed(at: date)),
            "elapsed_time_last_updated": .number(date.timeIntervalSince1970),
            "playback_speed": queue.raw["playback_speed"], "ended": queue.raw["ended"],
            "current_item": item
        ])
        timestamp = date
    }
}
#endif

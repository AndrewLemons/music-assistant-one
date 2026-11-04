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
        var player: JSONValue
        var queue: JSONValue
        var timestamp: Date

        init(server: ServerAddress, player: Player, queue: PlayerQueue, timestamp: Date = .now) {
            id = server.baseURL.absoluteString + "|" + player.id
            serverURL = server.baseURL
            playerID = player.id
            playerName = player.name
            self.player = .null
            self.queue = .null
            self.timestamp = timestamp
            updateQueue(queue, at: timestamp)
            updatePlayer(player)
        }

        mutating func updatePlayer(_ player: Player) {
            let fields = [
                "player_id",
                "name",
                "available",
                "type",
                "supported_features",
                "active_source",
                "volume_control",
                "volume_level",
                "group_volume",
                "synced_to",
                "group_members",
            ]
            var value = Dictionary(uniqueKeysWithValues: fields.map { ($0, player.raw[$0]) })
            value["source_list"] = .array(player.raw["source_list"].array.map { source in
                .object(Dictionary(uniqueKeysWithValues:
                    ["id", "can_play_pause", "can_seek", "can_next_previous", "can_shuffle", "can_repeat"]
                        .map { ($0, source[$0]) }))
            })
            self.player = .object(value)
        }

        mutating func updateQueue(_ queue: PlayerQueue, at date: Date = .now) {
            let server = try? ServerAddress(serverURL.absoluteString)
            let item: JSONValue = queue.current.map { media in
                var value: [String: JSONValue] = [
                    "uri": .string(media.id), "name": .string(media.name),
                    "artists": .array([.object(["name": .string(media.subtitle)])]),
                    "duration": .number(queue.duration),
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
                // A zero speed is the app's held optimistic start, not the speaker's rate.
                "playback_speed": (queue.raw["playback_speed"].double ?? 1) > 0 ? queue.raw["playback_speed"] : .null,
                "ended": queue.raw["ended"],
                "active": queue.raw["active"], "is_dynamic": queue.raw["is_dynamic"],
                "current_item": item,
            ])
            timestamp = date
        }
    }
#endif

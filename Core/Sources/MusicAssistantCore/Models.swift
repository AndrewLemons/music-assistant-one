import Foundation

public struct MediaItem: Identifiable, Sendable, Equatable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { uri }
    public var uri: String { raw["uri"].string ?? "\(raw["provider"].string ?? "library")://\(kind)/\(raw["item_id"].string ?? "")" }
    public var name: String { raw["name"].string ?? "Untitled" }
    public var kind: String { raw["media_type"].string ?? "track" }
    public var subtitle: String {
        let artists = raw["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        return artists.isEmpty ? (raw["owner"].string ?? kind.capitalized) : artists
    }
    public var duration: Double { raw["duration"].double ?? 0 }
    public var image: JSONValue {
        let images = raw["metadata"]["images"].array
        return images.first(where: { $0["type"].string == "thumb" }) ?? images.first ?? raw["image"]
    }
    public func artworkURL(server: ServerAddress?) -> URL? {
        if let proxy = image["proxy_id"].string, let server {
            return server.endpoint("imageproxy/\(proxy)")
        }
        if let path = image["path"].string, let url = URL(string: path), ["http", "https"].contains(url.scheme) { return url }
        return nil
    }
}

public struct Player: Identifiable, Sendable, Equatable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { raw["player_id"].string ?? "" }
    public var name: String { raw["name"].string ?? raw["display_name"].string ?? "Player" }
    public var provider: String { raw["provider"].string ?? "" }
    public var available: Bool { raw["available"].bool ?? false }
    public var visible: Bool { raw["enabled"].bool != false && raw["hide_in_ui"].bool != true }
    public var isPrivate: Bool { raw["private"].bool == true }
    public var state: String { raw["playback_state"].string ?? raw["state"].string ?? "idle" }
    public var volume: Double? { raw["group_volume"].double ?? raw["volume_level"].double }
    public var leader: String? { raw["synced_to"].string ?? raw["active_group"].string }
    public var members: [String] { (raw["group_members"] == .null ? raw["group_childs"] : raw["group_members"]).array.compactMap(\.string) }
    public var canLeave: Bool { leader != nil && !raw["static_group_members"].array.compactMap(\.string).contains(id) }
    public func canJoin(_ target: Player) -> Bool {
        guard available, target.available, id != target.id, target.leader == nil else { return false }
        let compatible = raw["can_group_with"].array.compactMap(\.string)
        return compatible.contains(target.id) || compatible.contains(target.provider)
    }
}

public struct PlayerQueue: Sendable, Equatable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { raw["queue_id"].string ?? "" }
    public var isPlaying: Bool { raw["state"].string == "playing" }
    public var current: MediaItem? {
        let item = raw["current_item"]
        guard item != .null else { return nil }
        return MediaItem(item["media_item"] == .null ? item : item["media_item"])
    }
    public var duration: Double { raw["current_item"]["duration"].double ?? current?.duration ?? 0 }
    public func elapsed(at date: Date = .now) -> Double {
        var elapsed = raw["elapsed_time"].double ?? 0
        // Some players reset their clock on pause/stop. MA retains the resume
        // position separately, including after its automatic pause-to-idle timeout.
        if !isPlaying, elapsed == 0, current != nil, raw["ended"].bool != true {
            elapsed = raw["resume_pos"].double ?? 0
        }
        let update = raw["elapsed_time_last_updated"].double ?? date.timeIntervalSince1970
        let delta = isPlaying ? max(0, date.timeIntervalSince1970 - update) * (raw["playback_speed"].double ?? 1) : 0
        return max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, elapsed + delta))
    }
    public var shuffle: Bool { raw["shuffle_enabled"].bool ?? false }
    public var repeatMode: String { raw["repeat_mode"].string ?? "off" }
}

public struct QueueEntry: Identifiable, Sendable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { raw["queue_item_id"].string ?? "" }
    public var media: MediaItem { MediaItem(raw["media_item"] == .null ? raw : raw["media_item"]) }
}

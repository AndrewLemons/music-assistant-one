import Foundation

public struct MediaItem: Identifiable, Sendable, Equatable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) {
        self.raw = raw
    }

    public var id: String {
        uri
    }

    public var uri: String {
        raw["uri"].string ?? "\(raw["provider"].string ?? "library")://\(kind)/\(raw["item_id"].string ?? "")"
    }

    public var name: String {
        raw["name"].string ?? "Untitled"
    }

    public var kind: String {
        raw["media_type"].string ?? "track"
    }

    public var isCollection: Bool {
        kind == "album" || kind == "playlist"
    }

    public var itemID: String {
        raw["item_id"].string ?? String(uri.split(separator: "/").last ?? "")
    }

    public var provider: String {
        raw["provider"].string ?? String(uri.split(separator: ":").first ?? "library")
    }

    public var isFavorite: Bool {
        raw["favorite"].bool == true
    }

    public var isEditablePlaylist: Bool {
        kind == "playlist" && provider == "library" && raw["is_editable"].bool == true
    }

    public var subtitle: String {
        let artists = raw["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        if !artists.isEmpty {
            return artists
        }
        if let owner = raw["owner"].string, !owner.isEmpty {
            return owner
        }
        // Play history references carry no credits; describe the kind instead.
        return switch kind {
        case "track": "Song"
        case "radio": "Radio Station"
        default: kind.capitalized
        }
    }

    public var duration: Double {
        raw["duration"].double ?? 0
    }

    /// The image proxy's sizes; artwork is requested at the first one covering the display.
    public static func thumbnailSize(_ pixels: Int) -> Int {
        [80, 160, 256, 512, 1024].first { $0 >= pixels } ?? 1024
    }

    public var year: Int? {
        raw["year"].double.flatMap { $0 > 0 ? Int($0) : nil }
    }

    /// Album, single, EP, or compilation, as Music Assistant reports it.
    public var albumType: String {
        raw["album_type"].string ?? "album"
    }

    /// The first credited artist, for links from songs and albums to an artist page.
    public var primaryArtist: MediaItem? {
        guard let artist = raw["artists"].array.first, artist["item_id"].string != nil || artist["uri"].string != nil
        else { return nil }
        return MediaItem(artist.merging(["media_type": .string("artist")]))
    }

    /// The album a song belongs to, when the server includes it.
    public var album: MediaItem? {
        let album = raw["album"]
        guard album != .null, album["item_id"].string != nil || album["uri"].string != nil else { return nil }
        return MediaItem(album.merging(["media_type": .string("album")]))
    }

    public var image: JSONValue {
        if raw["image"] != .null {
            return raw["image"]
        }
        let direct = raw["metadata"]["images"].array
        let album = raw["album"]["metadata"]["images"].array
        let images = !direct.isEmpty ? direct : !album.isEmpty ? album : raw["track_album"]["images"].array
        return images.first(where: { $0["type"].string == "thumb" }) ?? images.first ?? raw["image"]
    }

    /// `pixels` requests a server-side thumbnail, rounded up to a size the image proxy accepts.
    public func artworkURL(server: ServerAddress?, pixels: Int = 0) -> URL? {
        if let proxy = image["proxy_id"].string, let server {
            let url = server.endpoint("imageproxy/\(proxy)")
            guard pixels > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return url }
            components.queryItems = [URLQueryItem(name: "size", value: String(Self.thumbnailSize(pixels)))]
            return components.url ?? url
        }
        if let path = image["path"].string, let url = URL(string: path),
           ["http", "https"].contains(url.scheme)
        {
            return url
        }
        return nil
    }
}

public struct Player: Identifiable, Sendable, Equatable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) {
        self.raw = raw
    }

    public var id: String {
        raw["player_id"].string ?? ""
    }

    public var name: String {
        raw["name"].string ?? raw["display_name"].string ?? "Player"
    }

    public var provider: String {
        raw["provider"].string ?? ""
    }

    public var available: Bool {
        raw["available"].bool ?? false
    }

    public var visible: Bool {
        raw["enabled"].bool != false && raw["hide_in_ui"].bool != true
    }

    public var isPrivate: Bool {
        raw["private"].bool == true
    }

    /// The server enforces account access. `private` describes a device-local
    /// player, not an unconditional ban once its owner has made it visible.
    public func isVisiblePlaybackTarget(localPlayerID: String?) -> Bool {
        guard raw["enabled"].bool != false,
              raw["type"].string != "source", raw["type"].string != "protocol" else { return false }
        if represents(localPlayerID: localPlayerID) {
            return true
        }
        return raw["hide_in_ui"].bool != true
    }

    public func represents(localPlayerID: String?) -> Bool {
        guard let localPlayerID else { return false }
        return id == localPlayerID || raw["output_protocols"].array.contains {
            $0["output_protocol_id"].string == localPlayerID
        }
    }

    public var state: String {
        raw["playback_state"].string ?? raw["state"].string ?? "idle"
    }

    public var volume: Double? {
        raw["group_volume"].double ?? raw["volume_level"].double
    }

    public var leader: String? {
        raw["synced_to"].string ?? raw["active_group"].string
    }

    public var members: [String] {
        (raw["group_members"] == .null ? raw["group_childs"] : raw["group_members"]).array.compactMap(\.string)
    }

    public var canLeave: Bool {
        leader != nil && !raw["static_group_members"].array.compactMap(\.string).contains(id)
    }

    public func canJoin(_ target: Player) -> Bool {
        guard available, target.available, id != target.id, target.leader == nil else { return false }
        let compatible = raw["can_group_with"].array.compactMap(\.string)
        return compatible.contains(target.id) || compatible.contains(target.provider)
    }
}

public struct PlayerQueue: Sendable, Equatable {
    public let raw: JSONValue
    /// The server wall clock is never compared with the device wall clock.
    public let receivedAt: Date
    public private(set) var positionChange: Date?

    public init(_ raw: JSONValue, receivedAt: Date = .now, positionChange: Date? = nil) {
        self.raw = raw
        self.receivedAt = receivedAt
        self.positionChange = positionChange
    }

    public var itemID: String? {
        raw["current_item"]["queue_item_id"].string ?? current?.uri
    }

    /// Repeated reads of an unchanged server anchor must not restart interpolation.
    public func receiving(_ value: JSONValue, at date: Date = .now) -> PlayerQueue {
        var next = PlayerQueue(value, receivedAt: date)
        guard next.id == id else { return next }
        if next.itemID == itemID {
            next.positionChange = positionChange
            if value["elapsed_time"] == raw["elapsed_time"],
               value["elapsed_time_last_updated"] == raw["elapsed_time_last_updated"],
               value["state"] == raw["state"]
            {
                next = PlayerQueue(value, receivedAt: receivedAt)
                next.positionChange = positionChange
            }
        } else if value["elapsed_time_last_updated"] == raw["elapsed_time_last_updated"] {
            // Metadata can arrive before the new item's clock. Never reuse the old time.
            next = next.predicting(["elapsed_time": .number(0)], at: date)
        }
        return next
    }

    /// MA's numeric event payload is already track-relative, including flow mode and seeks.
    public func receivingTime(_ position: Double, at date: Date = .now) -> PlayerQueue {
        predicting(["elapsed_time": .number(position)], at: date)
    }

    public func applying(_ event: JSONValue, at date: Date = .now) -> PlayerQueue? {
        guard event["object_id"].string == id else { return nil }
        switch event["event"].string {
        case "queue_updated":
            guard event["data"]["queue_id"].string == id else { return nil }
            return receiving(event["data"], at: date)
        case "queue_time_updated":
            guard let position = event["data"].double, position.isFinite else { return nil }
            return receivingTime(position, at: date)
        default: return nil
        }
    }

    public var id: String {
        raw["queue_id"].string ?? ""
    }

    public var isPlaying: Bool {
        raw["state"].string == "playing"
    }

    public var current: MediaItem? {
        let item = raw["current_item"]
        guard item != .null else { return nil }
        guard item["media_item"] != .null else { return MediaItem(item) }
        // Queue artwork includes album/radio fallbacks absent from the nested track.
        let media = item["media_item"]
        return MediaItem(item["image"] == .null ? media : media.merging(["image": item["image"]]))
    }

    public var duration: Double {
        raw["current_item"]["duration"].double ?? current?.duration ?? 0
    }

    public func elapsed(at date: Date = .now) -> Double {
        var elapsed = raw["elapsed_time"].double ?? 0
        // Some players reset their clock on pause/stop. MA retains the resume
        // position separately, including after its automatic pause-to-idle timeout.
        if !isPlaying, elapsed == 0, current != nil, raw["ended"].bool != true {
            elapsed = raw["resume_pos"].double ?? 0
        }
        let delta = isPlaying ? max(0, date.timeIntervalSince(receivedAt)) * (raw["playback_speed"].double ?? 1) : 0
        return max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, elapsed + delta))
    }

    /// Freeze the interpolated clock when predicting transport changes, including seek-to-zero.
    public func predicting(_ fields: [String: JSONValue], at date: Date = .now) -> PlayerQueue {
        var patch = fields
        if fields["state"] != nil || fields["elapsed_time"] != nil {
            let position = fields["elapsed_time"]?.double ?? elapsed(at: date)
            patch["elapsed_time"] = .number(position)
            patch["resume_pos"] = .number(position)
            patch["elapsed_time_last_updated"] = .number(date.timeIntervalSince1970)
        }
        var result = PlayerQueue(
            raw.merging(patch),
            receivedAt: fields["state"] != nil || fields["elapsed_time"] != nil ? date : receivedAt
        )
        result.positionChange = fields["elapsed_time"] != nil ? date : positionChange
        return result
    }

    public var shuffle: Bool {
        raw["shuffle_enabled"].bool ?? false
    }

    public var repeatMode: String {
        raw["repeat_mode"].string ?? "off"
    }
}

public struct QueueEntry: Identifiable, Sendable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) {
        self.raw = raw
    }

    public var id: String {
        raw["queue_item_id"].string ?? ""
    }

    public var media: MediaItem {
        MediaItem(raw["media_item"] == .null ? raw : raw["media_item"])
    }
}

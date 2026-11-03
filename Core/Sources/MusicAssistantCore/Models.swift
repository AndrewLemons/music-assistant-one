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

public enum PlayerFeature: String, Sendable, CaseIterable {
    case volumeSet = "volume_set", volumeMute = "volume_mute", pause
    case setMembers = "set_members", seek, nextPrevious = "next_previous", playMedia = "play_media"
    case power, multiDeviceDSP = "multi_device_dsp", playAnnouncement = "play_announcement", enqueue
    case selectSoundMode = "select_sound_mode", selectSource = "select_source", options
    case gaplessPlayback = "gapless_playback", gaplessDifferentSampleRate = "gapless_different_samplerate"
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

    /// Protocol IDs are not queue owners. Linking can replace their playable parent.
    public func playbackTarget(in players: [Player]) -> Player? {
        if let parent = players.first(where: {
            $0.id != id && $0.raw["type"].string != "protocol" && $0.raw["type"].string != "source" &&
                $0.represents(localPlayerID: id)
        }) {
            return parent
        }
        return players.first { $0.id == id && $0.raw["type"].string != "protocol" && $0.raw["type"].string != "source" }
    }

    public var state: String {
        raw["playback_state"].string ?? raw["state"].string ?? "idle"
    }

    public var volume: Double? {
        // A null group_volume explicitly means that no powered member is controllable.
        // volume_level is still reported by clients without a volume command.
        if case let .object(fields) = raw, fields["group_volume"] != nil {
            return raw["group_volume"].double
        }
        return canSetVolume ? raw["volume_level"].double : nil
    }

    public var supportedFeatures: Set<PlayerFeature> {
        Set(raw["supported_features"].array.compactMap { $0.string.flatMap(PlayerFeature.init(rawValue:)) })
    }

    public var canSetVolume: Bool {
        raw["volume_control"].string != "none" && supportedFeatures.contains(.volumeSet)
    }

    /// MA's group_volume command follows synced_to, even when addressed to a member.
    public func volumeTarget(in players: [Player]) -> Player? {
        var target = self
        var visited: Set<String> = []
        while target.members.isEmpty, target.raw["type"].string != "group",
              let leader = target.raw["synced_to"].string, leader != target.id
        {
            guard visited.insert(target.id).inserted,
                  let parent = players.first(where: { $0.id == leader }) else { return nil }
            target = parent
        }
        guard target.available, target.volume != nil else { return nil }
        return !target.members.isEmpty || target.raw["type"].string == "group" || target.canSetVolume ? target : nil
    }

    public var volumeCommand: String {
        !members.isEmpty || raw["type"].string == "group" ? "group_volume" : "volume_set"
    }

    /// Native features describe the renderer, not MA's queue operations. Sendspin has
    /// no native seek/skip/pause but MA implements those by rebuilding its stream.
    public func supports(_ command: String, queue: PlayerQueue?) -> Bool {
        let source = raw["source_list"].array.first { $0["id"].string == raw["active_source"].string }
        let ownsQueue = queue.map {
            !$0.id.isEmpty && ($0.raw["active"].bool == true || raw["active_source"].string == $0.id)
        } ?? false
        switch command {
        case "play", "pause":
            return source?["can_play_pause"].bool ?? (ownsQueue || supportedFeatures.contains(.pause))
        case "next", "previous":
            return source?["can_next_previous"].bool ?? (ownsQueue || supportedFeatures.contains(.nextPrevious))
        case "seek":
            return (queue?.duration ?? 0) > 0 &&
                (source?["can_seek"].bool ?? (ownsQueue || supportedFeatures.contains(.seek)))
        case "shuffle": return ownsQueue ? queue?.raw["is_dynamic"].bool != true : source?["can_shuffle"].bool == true
        case "repeat": return ownsQueue || source?["can_repeat"].bool == true
        case "stop": return true
        default: return false
        }
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

    public func canLeave(in players: [Player]) -> Bool {
        guard let leader, let parent = players.first(where: { $0.id == leader }), parent.available,
              !parent.raw["static_group_members"].array.compactMap(\.string).contains(id) else { return false }
        return parent.supportedFeatures.contains(.setMembers)
    }

    public func canJoin(_ target: Player) -> Bool {
        guard available, target.available, id != target.id, target.leader == nil,
              target.supportedFeatures.contains(.setMembers) else { return false }
        let compatible = raw["can_group_with"].array.compactMap(\.string)
        return compatible.contains(target.id) || compatible.contains(target.provider)
    }
}

public struct PlayerQueue: Sendable, Equatable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) {
        self.raw = raw
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
        let update = raw["elapsed_time_last_updated"].double ?? date.timeIntervalSince1970
        let delta = isPlaying ? max(0, date.timeIntervalSince1970 - update) * (raw["playback_speed"].double ?? 1) : 0
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
        return PlayerQueue(raw.merging(patch))
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

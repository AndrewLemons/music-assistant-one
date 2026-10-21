import Foundation

/// A queue belongs to this installation, rather than to a network speaker.
/// Occurrence IDs survive persistence, including repeated copies of one track.
public struct DevicePlaybackQueue: Codable, Sendable, Equatable {
    public static let playerID = "one:this-device"
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let metadata: JSONValue
        public let order: Int
        public var media: MediaItem {
            MediaItem(metadata)
        }

        public init(media: MediaItem, order: Int, id: String = UUID().uuidString) {
            self.id = id
            metadata = media.offlineMetadata
            self.order = order
        }

        public var queueEntry: QueueEntry {
            QueueEntry(.object(["queue_item_id": .string(id), "media_item": metadata]))
        }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var currentID: String?
    public private(set) var position: Double = 0
    public private(set) var shuffle = false
    public private(set) var repeatMode = "off"
    public var currentIndex: Int? {
        entries.firstIndex { $0.id == currentID }
    }

    public var current: Entry? {
        currentIndex.map { entries[$0] }
    }

    public var upcoming: [Entry] {
        Array(entries.dropFirst((currentIndex ?? -1) + 1))
    }

    public init() {}

    public mutating func insert(_ media: [MediaItem], option: String = "replace") {
        guard !media.isEmpty else { return }
        let order = (entries.map(\.order).max() ?? -1) + 1
        var added = media.enumerated().map { Entry(media: $0.element, order: order + $0.offset) }
        if shuffle {
            added.shuffle()
        }
        switch option {
        case "next": entries.insert(contentsOf: added, at: (currentIndex ?? -1) + 1)
        case "add": entries.append(contentsOf: added)
        default:
            entries = added
            currentID = entries.first?.id
            position = 0
        }
        if currentID == nil {
            currentID = entries.first?.id; position = 0
        }
    }

    @discardableResult public mutating func select(_ id: String) -> Bool {
        guard entries.contains(where: { $0.id == id }) else { return false }
        currentID = id; position = 0
        return true
    }

    public mutating func seek(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        position = min(seconds, current?.media.duration.flatPositive ?? seconds)
    }

    /// An explicit Next ignores Repeat One. Natural completion honors it.
    @discardableResult public mutating func advance(automatically: Bool = false) -> Bool {
        guard let index = currentIndex else { return false }
        if automatically, repeatMode == "one" {
            position = 0; return true
        }
        if entries.indices.contains(index + 1) {
            return select(entries[index + 1].id)
        }
        if repeatMode == "all", let first = entries.first {
            return select(first.id)
        }
        return false
    }

    public mutating func previous() {
        if position > 3 {
            position = 0; return
        }
        guard let index = currentIndex else { return }
        if index > 0 {
            _ = select(entries[index - 1].id)
        } else {
            position = 0
        }
    }

    public mutating func setShuffle(_ enabled: Bool) {
        guard enabled != shuffle else { return }
        shuffle = enabled
        let boundary = (currentIndex ?? -1) + 1
        var tail = Array(entries.dropFirst(boundary))
        if enabled {
            tail.shuffle()
        } else {
            tail.sort { $0.order < $1.order }
        }
        entries = Array(entries.prefix(boundary)) + tail
    }

    public mutating func setRepeat(_ mode: String) {
        guard ["off", "all", "one"].contains(mode) else { return }
        repeatMode = mode
    }

    @discardableResult public mutating func move(_ id: String, shift: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              index > (currentIndex ?? -1), index + shift > (currentIndex ?? -1),
              entries.indices.contains(index + shift), shift != 0 else { return false }
        entries.insert(entries.remove(at: index), at: index + shift)
        return true
    }

    public mutating func remove(_ id: String) {
        guard id != currentID, upcoming.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
    }

    public func snapshot(playing: Bool, at date: Date = .now) -> PlayerQueue {
        PlayerQueue(.object([
            "queue_id": .string(Self.playerID), "state": .string(playing ? "playing" : "paused"),
            "elapsed_time": .number(position), "resume_pos": .number(position),
            "elapsed_time_last_updated": .number(date.timeIntervalSince1970),
            "shuffle_enabled": .bool(shuffle), "repeat_mode": .string(repeatMode),
            "current_index": currentIndex.map { .number(Double($0)) } ?? .null,
            "current_item": current.map { .object([
                "queue_item_id": .string($0.id), "duration": .number($0.media.duration), "media_item": $0.metadata,
            ]) } ?? .null,
        ]))
    }
}

private extension Double {
    var flatPositive: Double? {
        isFinite && self > 0 ? self : nil
    }
}

public extension MediaItem {
    /// Allowlist metadata persisted on disk. Never retain provider stream details or credentials.
    var offlineMetadata: JSONValue {
        .object([
            "uri": .string(uri), "item_id": .string(itemID), "provider": .string(provider),
            "name": .string(name), "media_type": .string(kind),
            "duration": .number(duration.isFinite ? max(0, duration) : 0),
            "artists": .array(raw["artists"].array.map { .object(["name": $0["name"]]) }),
            "owner": raw["owner"], "image": image, "favorite": .bool(isFavorite),
        ])
    }
}

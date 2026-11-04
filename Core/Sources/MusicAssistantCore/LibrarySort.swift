import Foundation

/// A library list order that Music Assistant 2.10.9 sorts on the server, before pagination.
///
/// Each collection offers only the keys its summary query can order by: tracks have no year
/// column, and only tracks and albums join artists for an artist sort.
public struct LibrarySort: Hashable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case title, artist, dateAdded, year, duration, mostPlayed, recentlyPlayed

        /// Play counts and recency read best in one direction only.
        public var hasDirection: Bool {
            self != .mostPlayed && self != .recentlyPlayed
        }

        /// The direction a field starts in when chosen: names A to Z, dates newest first.
        public var defaultAscending: Bool {
            switch self {
            case .title, .artist, .duration: true
            case .dateAdded, .year, .mostPlayed, .recentlyPlayed: false
            }
        }
    }

    public var field: Field
    public var ascending: Bool

    public init(_ field: Field, ascending: Bool? = nil) {
        self.field = field
        self.ascending = field.hasDirection ? ascending ?? field.defaultAscending : field.defaultAscending
    }

    /// The fields a library collection (`tracks`, `albums`, `artists`, `playlists`) supports.
    public static func fields(for collection: String) -> [Field] {
        switch collection {
        case "tracks": [.title, .artist, .dateAdded, .duration, .mostPlayed, .recentlyPlayed]
        case "albums": [.title, .artist, .dateAdded, .year, .mostPlayed, .recentlyPlayed]
        default: [.title, .dateAdded, .mostPlayed, .recentlyPlayed]
        }
    }

    public static let `default` = LibrarySort(.title)

    /// This sort, or the default when the collection can't order by its field.
    public func supported(by collection: String) -> LibrarySort {
        Self.fields(for: collection).contains(field) ? self : .default
    }

    /// The `order_by` key for `music/<collection>/library_items`.
    public func orderKey(for collection: String) -> String {
        let sort = supported(by: collection)
        let base = switch sort.field {
        case .title: "sort_name"
        case .artist: collection == "tracks" ? "track_artist_name" : "album_artist_name"
        case .dateAdded: "timestamp_added"
        case .year: "year"
        case .duration: "duration"
        case .mostPlayed: "play_count"
        case .recentlyPlayed: "last_played"
        }
        return sort.ascending ? base : base + "_desc"
    }

    /// The same order applied to cached items while offline, as closely as their metadata allows.
    /// Items without a value follow the others in their cached order. Play counts aren't cached.
    public func sorted(_ items: [MediaItem]) -> [MediaItem] {
        func text(_ item: MediaItem) -> String {
            item.raw["sort_name"].string ?? item.name
        }
        switch field {
        case .title:
            return ordered(items.map { ($0, text($0)) }, by: { $0.localizedStandardCompare($1) })
        case .artist:
            return ordered(items.map { ($0, [$0.subtitle, text($0)]) }, by: { a, b in
                let artist = a[0].localizedStandardCompare(b[0])
                return artist == .orderedSame ? a[1].localizedStandardCompare(b[1]) : artist
            })
        case .dateAdded:
            return ordered(items, value: { $0.raw["date_added"].string })
        case .year:
            return ordered(items, value: \.year)
        case .duration:
            return ordered(items, value: { $0.duration > 0 ? $0.duration : nil })
        case .recentlyPlayed:
            return ordered(items, value: { $0.raw["last_played"].double.flatMap { $0 > 0 ? $0 : nil } })
        case .mostPlayed:
            return items
        }
    }

    private func ordered(_ items: [MediaItem], value: (MediaItem) -> (some Comparable)?) -> [MediaItem] {
        let present = items.compactMap { item in value(item).map { (item, $0) } }
        let missing = items.filter { value($0) == nil }
        return ordered(present, by: { $0 < $1 ? .orderedAscending : $0 > $1 ? .orderedDescending : .orderedSame })
            + missing
    }

    /// A stable sort in this direction: equal values keep their cached order.
    private func ordered<Key>(_ keyed: [(MediaItem, Key)], by compare: (Key, Key) -> ComparisonResult) -> [MediaItem] {
        keyed.enumerated().sorted { a, b in
            let result = compare(a.element.1, b.element.1)
            return result == .orderedSame ? a.offset < b.offset : (result == .orderedAscending) == ascending
        }.map(\.element.0)
    }
}

extension LibrarySort: RawRepresentable {
    /// "dateAdded.descending", for app storage.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".")
        guard parts.count == 2, let field = Field(rawValue: String(parts[0])),
              ["ascending", "descending"].contains(parts[1]) else { return nil }
        self.init(field, ascending: parts[1] == "ascending")
    }

    public var rawValue: String {
        "\(field.rawValue).\(ascending ? "ascending" : "descending")"
    }
}

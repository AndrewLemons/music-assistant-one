import Foundation
@testable import MusicAssistantCore
import Testing

private func song(_ index: Int, _ extra: [String: JSONValue] = [:]) -> MediaItem {
    MediaItem(JSONValue.object([
        "uri": .string("library://track/\(index)"),
        "name": .string("Track \(index)"),
        "media_type": .string("track"),
        "duration": .number(180),
    ]).merging(extra))
}

// MARK: Sorting

@Test func sortKeysMatchMusicAssistantPerCollection() {
    #expect(LibrarySort(.title).orderKey(for: "tracks") == "sort_name")
    #expect(LibrarySort(.title, ascending: false).orderKey(for: "albums") == "sort_name_desc")
    #expect(LibrarySort(.artist).orderKey(for: "tracks") == "track_artist_name")
    #expect(LibrarySort(.artist, ascending: false).orderKey(for: "albums") == "album_artist_name_desc")
    #expect(LibrarySort(.dateAdded).orderKey(for: "playlists") == "timestamp_added_desc")
    #expect(LibrarySort(.dateAdded, ascending: true).orderKey(for: "artists") == "timestamp_added")
    #expect(LibrarySort(.year).orderKey(for: "albums") == "year_desc")
    #expect(LibrarySort(.duration).orderKey(for: "tracks") == "duration")
    #expect(LibrarySort(.mostPlayed).orderKey(for: "albums") == "play_count_desc")
    #expect(LibrarySort(.recentlyPlayed).orderKey(for: "tracks") == "last_played_desc")
    // Play counts and recency have one direction; unsupported fields fall back to Title.
    #expect(LibrarySort(.mostPlayed, ascending: true).orderKey(for: "tracks") == "play_count_desc")
    #expect(LibrarySort(.year).orderKey(for: "tracks") == "sort_name")
    #expect(LibrarySort(.artist).orderKey(for: "playlists") == "sort_name")
    #expect(LibrarySort.fields(for: "tracks") == [.title, .artist, .dateAdded, .duration, .mostPlayed, .recentlyPlayed])
    #expect(LibrarySort.fields(for: "albums").contains(.year))
    #expect(LibrarySort.fields(for: "artists") == [.title, .dateAdded, .mostPlayed, .recentlyPlayed])
}

@Test func sortRoundTripsThroughStorage() {
    for field in LibrarySort.Field.allCases {
        for ascending in [true, false] {
            let sort = LibrarySort(field, ascending: ascending)
            #expect(LibrarySort(rawValue: sort.rawValue) == sort)
        }
    }
    #expect(LibrarySort(rawValue: "Library Order") == nil)
    #expect(LibrarySort(rawValue: "title.sideways") == nil)
}

@Test func offlineSortIsStableAndKeepsMissingValuesLast() {
    let items = [
        song(0, ["year": .number(1999), "artists": .array([.object(["name": .string("B")])])]),
        song(1, ["artists": .array([.object(["name": .string("A")])])]),
        song(2, ["year": .number(2020), "artists": .array([.object(["name": .string("B")])])]),
        song(3, ["year": .number(1999)]),
    ]
    let names = { (sort: LibrarySort) in sort.sorted(items).map(\.name) }
    #expect(names(LibrarySort(.year)) == ["Track 2", "Track 0", "Track 3", "Track 1"])
    #expect(names(LibrarySort(.year, ascending: true)) == ["Track 0", "Track 3", "Track 2", "Track 1"])
    #expect(names(LibrarySort(.artist)) == ["Track 1", "Track 0", "Track 2", "Track 3"])
    #expect(names(LibrarySort(.title, ascending: false)) == ["Track 3", "Track 2", "Track 1", "Track 0"])
    #expect(names(LibrarySort(.mostPlayed)) == items.map(\.name))
}

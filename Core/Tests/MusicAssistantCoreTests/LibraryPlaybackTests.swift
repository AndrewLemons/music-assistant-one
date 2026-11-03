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

private let songs = MediaPageRequest.library(collection: "tracks", search: "", order: "sort_name")

// MARK: Progressive queues

@MainActor @Test func continuationDeliversPendingThenPagesWithoutDuplicates() async throws {
    var offsets: [Int] = []
    var delivered: [[String]] = []
    try await LibraryQueue.continueLoading(
        pending: (100 ..< 130).map { song($0) },
        then: songs,
        from: 130,
        queued: Set((0 ..< 100).map { song($0).id }),
        pageSize: 50,
        fetch: { _, offset, limit in
            offsets.append(offset)
            // The server repeats one song across a page boundary.
            return (offset ..< min(offset + limit, 237)).map { song($0 == 180 ? 179 : $0) }
        },
        deliver: { delivered.append($0.map(\.id)) }
    )
    #expect(offsets == [130, 180, 230])
    #expect(delivered.map(\.count) == [30, 50, 49, 7])
    let all = delivered.flatMap(\.self)
    #expect(Set(all).count == all.count)
    #expect(all.count == 136)
}

@MainActor @Test func continuationStopsAtTheSongLimit() async throws {
    var fetches = 0
    var delivered = 0
    try await LibraryQueue.continueLoading(
        then: songs,
        from: 100,
        queued: Set((0 ..< 100).map { song($0).id }),
        limit: 260,
        pageSize: 100,
        fetch: { _, offset, limit in
            fetches += 1
            return (offset ..< offset + limit).map { song($0) }
        },
        deliver: { delivered += $0.count }
    )
    #expect(delivered == 160)
    #expect(fetches == 2)
}

@MainActor @Test func continuationStopsWhenCancelledOrDeliveryFails() async {
    let task = Task { @MainActor in
        try await LibraryQueue.continueLoading(
            then: songs, from: 0, queued: [], pageSize: 10,
            fetch: { _, offset, limit in (offset ..< offset + limit).map { song($0) } },
            deliver: { _ in withUnsafeCurrentTask { $0?.cancel() } }
        )
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: MAError.self) {
        try await LibraryQueue.continueLoading(
            then: songs, from: 0, queued: [], pageSize: 10,
            fetch: { _, offset, limit in (offset ..< offset + limit).map { song($0) } },
            deliver: { _ in throw MAError.message("Queue unavailable") }
        )
    }
}

@Test func shuffledRequestKeepsFilterAndUsesServerRandomOrder() {
    let filtered = MediaPageRequest.library(collection: "tracks", search: "live", order: "duration_desc")
    #expect(LibraryQueue.shuffled(filtered) == .library(collection: "tracks", search: "live", order: "random"))
    #expect(LibraryQueue.shuffled(filtered).arguments(offset: 0, limit: 100)["search"] == .string("live"))
}

// MARK: Device queue

@Test func deviceQueueStartsWhereAsked() {
    var queue = DevicePlaybackQueue()
    queue.setShuffle(true)
    // Choosing the first song plays it, even with shuffle on.
    for _ in 0 ..< 10 {
        queue.insert((0 ..< 30).map { song($0) }, start: 0)
        #expect(queue.current?.media.name == "Track 0")
    }
    // Shuffle without a chosen song starts anywhere.
    var firsts = Set<String>()
    for _ in 0 ..< 30 {
        queue.insert((0 ..< 30).map { song($0) })
        firsts.insert(queue.current?.media.name ?? "")
    }
    #expect(firsts.count > 1)
    queue.setShuffle(false)
    queue.insert((0 ..< 3).map { song($0) })
    #expect(queue.current?.media.name == "Track 0")
}

@Test func appendingContinuesInOrderOrMixesIntoUpcomingSongs() {
    var ordered = DevicePlaybackQueue()
    ordered.insert((0 ..< 3).map { song($0) }, start: 1)
    ordered.append((3 ..< 6).map { song($0) })
    #expect(ordered.current?.media.name == "Track 1")
    #expect(ordered.entries.map(\.media.name) == (0 ..< 6).map { "Track \($0)" })

    var shuffled = DevicePlaybackQueue()
    shuffled.setShuffle(true)
    shuffled.insert((0 ..< 10).map { song($0) }, start: 4)
    let before = shuffled.entries.map(\.id)
    shuffled.append((10 ..< 200).map { song($0) })
    let after = shuffled.entries.map(\.id)
    // The current song and the prepared next song stay; earlier upcoming songs keep their order.
    #expect(Array(after.prefix(2)) == Array(before.prefix(2)))
    #expect(after.filter(before.contains) == before)
    #expect(after.count == 200)
    // New songs land among the upcoming songs, not only after them.
    let lastOriginal = after.lastIndex { before.contains($0) } ?? 0
    #expect(lastOriginal > before.count)
    shuffled.setShuffle(false)
    #expect(shuffled.upcoming.map(\.media.name) == ([0, 1, 2, 3] + Array(5 ..< 200)).map { "Track \($0)" })
}

// MARK: Fixture server

@MainActor @Test func libraryShuffleAndSortedContinuationOverWebSocket() async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    _ = try await client.connect(server: server.address, token: "fixture-token")
    let fetch: LibraryQueue.Fetch = { request, offset, limit in
        try await request.items(in: client.command(
            request.command,
            args: request.arguments(offset: offset, limit: limit)
        ))
    }
    // Every sort offered for songs is accepted; a year sort isn't, which is why it isn't offered.
    for field in LibrarySort.fields(for: "tracks") {
        for ascending in [true, false] {
            let order = LibrarySort(field, ascending: ascending).orderKey(for: "tracks")
            _ = try await fetch(.library(collection: "tracks", search: "", order: order), 0, 5)
        }
    }
    await #expect(throws: MAError.self) {
        try await fetch(.library(collection: "tracks", search: "", order: "year"), 0, 5)
    }

    // Play: the songs shown, then the rest in the same server order.
    let longest = MediaPageRequest.library(collection: "tracks", search: "", order: "duration_desc")
    let shown = try await fetch(longest, 0, 100)
    var queue = shown
    try await LibraryQueue.continueLoading(
        then: longest, from: shown.count, queued: Set(shown.map(\.id)), pageSize: 50, fetch: fetch,
        deliver: { queue += $0 }
    )
    let everything = try await fetch(longest, 0, 500)
    #expect(queue.map(\.id) == everything.map(\.id))
    #expect(zip(queue, queue.dropFirst()).allSatisfy { $0.duration >= $1.duration })

    // Shuffle: one random page, then every other song once.
    let sample = try await fetch(LibraryQueue.shuffled(songs), 0, LibraryQueue.shuffleSampleSize)
    #expect(sample.count == 100)
    var shuffled = sample
    try await LibraryQueue.continueLoading(
        then: songs, from: 0, queued: Set(sample.map(\.id)), fetch: fetch, deliver: { shuffled += $0 }
    )
    #expect(shuffled.count == 237)
    #expect(Set(shuffled.map(\.id)).count == 237)

    // A filter applies to the random page too.
    let filtered = try await fetch(
        LibraryQueue.shuffled(.library(collection: "tracks", search: "Track 23", order: "")),
        0,
        100
    )
    #expect(Set(filtered.map(\.name)) == Set((230 ..< 237).map { "Track \($0)" }))
    await client.disconnect()
}

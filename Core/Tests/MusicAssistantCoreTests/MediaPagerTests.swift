import Foundation
import Testing
@testable import MusicAssistantCore

private func media(_ index: Int) -> MediaItem {
    MediaItem(.object(["uri": .string("library://track/\(index)"), "name": .string("Track \(index)"), "media_type": .string("track")]))
}
private let libraryRequest = MediaPageRequest.library(collection: "tracks", search: "", order: "sort_name")

@MainActor @Test func libraryScrollsPastSixtyUntilShortFinalPage() async {
    let page = MediaPager()
    page.reset(libraryRequest)
    var offsets: [Int] = []
    for _ in 0..<4 {
        await page.loadNext { _, offset, limit in
            offsets.append(offset)
            return (offset..<min(offset + limit, 235)).map(media)
        }
    }
    #expect(offsets == [0, 100, 200])
    #expect(page.items.count == 235)
    #expect(page.offset == 235)
    #expect(!page.hasMore)
}

@MainActor @Test func deduplicationDoesNotSkipWireOffsets() async {
    let page = MediaPager(pageSize: 2)
    page.reset(libraryRequest)
    await page.loadNext { _, _, _ in [media(0), media(0)] }
    #expect(page.items.count == 1)
    #expect(page.offset == 2)
    await page.loadNext { _, offset, _ in
        #expect(offset == 2)
        return [media(1), media(2)]
    }
    #expect(page.items.map(\.id) == (0..<3).map { media($0).id })
    await page.loadNext { _, _, _ in [] }
    #expect(!page.hasMore)
}

@MainActor @Test func searchExpandsGeometricallyAndKeepsUniqueResults() async {
    let page = MediaPager(pageSize: 25)
    page.reset(.search(query: "track", kind: "track"))
    var limits: [Int] = []
    for _ in 0..<4 {
        await page.loadNext { _, _, limit in
            limits.append(limit)
            return (0..<min(limit, 97)).map(media)
        }
    }
    #expect(limits == [25, 50, 100])
    #expect(page.items.count == 97)
    #expect(Set(page.items.map(\.id)).count == 97)
    #expect(!page.hasMore)
}

@MainActor @Test func providerRepeatingFullResultsDoesNotLoop() async {
    let page = MediaPager(pageSize: 2)
    page.reset(.search(query: "track", kind: "track"))
    await page.loadNext { _, _, _ in [media(0), media(1)] }
    await page.loadNext { _, _, _ in [media(0), media(1), media(0), media(1)] }
    #expect(!page.hasMore)
    #expect(page.items.count == 2)
}

@MainActor @Test func failedPageRetriesSameCursorWithoutClearingResults() async {
    let page = MediaPager(pageSize: 2)
    page.reset(libraryRequest)
    await page.loadNext { _, _, _ in [media(0), media(1)] }
    await page.loadNext { _, _, _ in throw MAError.message("Offline") }
    #expect(page.error == "Offline")
    #expect(page.items.count == 2)
    #expect(page.offset == 2)
    #expect(page.hasMore)
    await page.loadNext { _, offset, _ in
        #expect(offset == 2)
        return [media(2)]
    }
    #expect(page.error == nil)
    #expect(page.items.count == 3)
    #expect(!page.hasMore)
}

@MainActor private final class PageGate {
    var continuation: CheckedContinuation<[MediaItem], any Error>?
    func wait() async throws -> [MediaItem] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<[MediaItem], any Error>) { continuation?.resume(with: result); continuation = nil }
}

@MainActor @Test func duplicateLoadsCoalesceAndResetRejectsLateResponse() async {
    let page = MediaPager(pageSize: 2)
    let gate = PageGate()
    page.reset(libraryRequest)
    let old = Task { await page.loadNext { _, _, _ in try await gate.wait() } }
    while gate.continuation == nil { await Task.yield() }
    #expect(page.isLoading)
    await page.loadNext { _, _, _ in Issue.record("Duplicate request issued"); return [] }
    page.reset(.library(collection: "tracks", search: "new query", order: "sort_name"))
    await page.loadNext { _, _, _ in [media(99)] }
    gate.finish(.success([media(0), media(1)]))
    await old.value
    #expect(page.items.map(\.id) == [media(99).id])
    #expect(page.error == nil)
    #expect(!page.isLoading)
}

@MainActor @Test func resetRejectsLateErrorAndCancellationRemainsRetryable() async {
    let page = MediaPager()
    let gate = PageGate()
    page.reset(libraryRequest)
    let old = Task { await page.loadNext { _, _, _ in try await gate.wait() } }
    while gate.continuation == nil { await Task.yield() }
    page.reset(libraryRequest, cached: [media(7)])
    gate.finish(.failure(MAError.message("Old failure")))
    await old.value
    #expect(page.error == nil)
    #expect(page.items.map(\.id) == [media(7).id])
    await page.loadNext { _, _, _ in throw CancellationError() }
    #expect(page.error == nil)
    #expect(page.hasMore)
    #expect(!page.isLoading)
    await page.loadNext { _, offset, _ in
        #expect(offset == 0)
        return [media(8)]
    }
    #expect(page.items.map(\.id) == [media(8).id])
}

@Test func requestsUseServerPaginationAndSortingContract() {
    let library = MediaPageRequest.library(collection: "albums", search: "Miles", order: "timestamp_added_desc")
    #expect(library.command == "music/albums/library_items")
    #expect(library.arguments(offset: 100, limit: 100) == [
        "search": .string("Miles"), "order_by": .string("timestamp_added_desc"), "offset": .number(100), "limit": .number(100)
    ])
    let search = MediaPageRequest.search(query: "Miles", kind: "track")
    #expect(search.command == "music/search")
    #expect(search.arguments(offset: 25, limit: 50)["offset"] == nil)
    #expect(search.arguments(offset: 25, limit: 50)["media_types"] == .array([.string("track")]))
    #expect(search.items(in: .object(["tracks": .array([media(0).raw])])) == [media(0)])
    #expect(library.items(in: .object(["items": .array([media(1).raw])] )) == [media(1)])
    #expect(library.items(in: .array([media(2).raw])) == [media(2)])
    #expect(MediaPageRequest.search(query: "radio", kind: "radio").items(in: .object(["radio": .array([media(3).raw])])) == [media(3)])
}

@MainActor @Test func exactPageBoundaryRequiresOneEmptyProbe() async {
    let page = MediaPager(pageSize: 2)
    page.reset(libraryRequest)
    await page.loadNext { _, _, _ in [media(0), media(1)] }
    #expect(page.hasMore)
    await page.loadNext { _, offset, _ in
        #expect(offset == 2)
        return []
    }
    #expect(!page.hasMore)
    #expect(page.items.count == 2)
}

@MainActor @Test func cancellingCallerRejectsUncooperativeTransportResult() async {
    let page = MediaPager()
    let gate = PageGate()
    page.reset(libraryRequest)
    let loading = Task { await page.loadNext { _, _, _ in try await gate.wait() } }
    while gate.continuation == nil { await Task.yield() }
    loading.cancel()
    gate.finish(.success([media(0)]))
    await loading.value
    #expect(page.items.isEmpty)
    #expect(page.offset == 0)
    #expect(page.error == nil)
    #expect(!page.isLoading)
    await page.loadNext { _, _, _ in [media(1)] }
    #expect(page.items.map(\.id) == [media(1).id])
}

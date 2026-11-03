import Foundation

/// Plays a library list, such as all songs, without first loading the whole library.
///
/// Music Assistant 2.10.9 has no media URI for a library list, so playback starts with the
/// songs already shown (or one random page for Shuffle) and the rest of the list follows
/// in server order, page by page, up to `songLimit`.
@MainActor
public enum LibraryQueue {
    /// Queues stay responsive to edit and persist; a longer library continues by choosing again.
    public static let songLimit = 2000
    /// Continuation pages match Music Assistant's default `library_items` limit.
    public static let pageSize = 500
    /// Shuffle starts from this many random songs, so the first song can come from anywhere.
    public static let shuffleSampleSize = 100

    public typealias Fetch = (MediaPageRequest, _ offset: Int, _ limit: Int) async throws -> [MediaItem]

    /// The same list in a random server-side order, for Shuffle's first page.
    public nonisolated static func shuffled(_ request: MediaPageRequest) -> MediaPageRequest {
        guard case let .library(collection, search, _) = request else { return request }
        return .library(collection: collection, search: search, order: "random")
    }

    /// Delivers `pending` songs, then fetches `request` from `offset`, skipping songs already
    /// queued, until the queue holds `limit` songs or the list ends. Each delivery is at most
    /// `pageSize` songs. Cancellation stops between deliveries.
    public static func continueLoading(
        pending: [MediaItem] = [],
        then request: MediaPageRequest?,
        from offset: Int,
        queued: Set<String>,
        limit: Int = songLimit,
        pageSize: Int = pageSize,
        fetch: Fetch,
        deliver: ([MediaItem]) async throws -> Void
    ) async throws {
        precondition(pageSize > 0)
        var queued = queued
        func take(_ items: some Sequence<MediaItem>) -> [MediaItem] {
            var batch: [MediaItem] = []
            for item in items {
                guard queued.count < limit else { break }
                if queued.insert(item.id).inserted {
                    batch.append(item)
                }
            }
            return batch
        }
        var remaining = pending[...]
        while !remaining.isEmpty, queued.count < limit {
            try Task.checkCancellation()
            let batch = take(remaining.prefix(pageSize))
            remaining = remaining.dropFirst(pageSize)
            if !batch.isEmpty {
                try await deliver(batch)
            }
        }
        guard let request else { return }
        var offset = offset
        while queued.count < limit {
            try Task.checkCancellation()
            let page = try await fetch(request, offset, pageSize)
            try Task.checkCancellation()
            // Advance by the wire count, as the pager does, so duplicates never skip songs.
            offset += page.count
            let batch = take(page)
            if !batch.isEmpty {
                try await deliver(batch)
            }
            if page.count < pageSize {
                return
            }
        }
    }
}

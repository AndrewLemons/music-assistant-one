import Foundation
import Observation

/// Library APIs return offset pages; global search only supports an expanding limit.
public enum MediaPageRequest: Equatable, Sendable {
    case library(collection: String, search: String, order: String)
    case search(query: String, kind: String)

    public var command: String {
        switch self {
        case let .library(collection, _, _): "music/\(collection)/library_items"
        case .search: "music/search"
        }
    }

    public var expandsResults: Bool {
        if case .search = self {
            true
        } else {
            false
        }
    }

    public func arguments(offset: Int, limit: Int) -> [String: JSONValue] {
        switch self {
        case let .library(_, search, order):
            var args: [String: JSONValue] = [
                "offset": .number(Double(offset)),
                "limit": .number(Double(limit)),
                "order_by": .string(order),
            ]
            if !search.isEmpty {
                args["search"] = .string(search)
            }
            return args
        case let .search(query, kind):
            return [
                "search_query": .string(query),
                "media_types": .array([.string(kind)]),
                "limit": .number(Double(limit)),
            ]
        }
    }

    public func items(in response: JSONValue) -> [MediaItem] {
        let value: JSONValue = if case let .search(_, kind) = self {
            response[kind == "radio" ? "radio" : "\(kind)s"]
        } else {
            response
        }
        return (value["items"] == .null ? value.array : value["items"].array).map(MediaItem.init)
    }
}

/// One in-flight request per list. Reset/cancellation invalidates late responses, even
/// from transports that ignore cancellation. Failed requests retain their cursor.
@MainActor @Observable
public final class MediaPager {
    public private(set) var items: [MediaItem] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = true
    public private(set) var error: String?
    public private(set) var request: MediaPageRequest?
    public private(set) var offset = 0
    public private(set) var limit: Int
    private let pageSize: Int
    @ObservationIgnored private var ids: Set<String> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<[MediaItem], any Error>?

    public init(pageSize: Int = 100) {
        precondition(pageSize > 0)
        self.pageSize = pageSize
        limit = pageSize
    }

    public func reset(_ request: MediaPageRequest? = nil, cached: [MediaItem] = []) {
        suspend()
        self.request = request
        items = cached
        ids = []
        offset = 0
        limit = pageSize
        error = nil
        hasMore = request != nil
    }

    public func suspend() {
        generation = UUID()
        task?.cancel(); task = nil
        isLoading = false
    }

    public func loadNext(fetch: @escaping @MainActor @Sendable (MediaPageRequest, Int, Int) async throws
        -> [MediaItem]) async
    {
        guard !isLoading, hasMore, let request else { return }
        isLoading = true
        error = nil
        let epoch = generation
        let requestedOffset = offset
        let requestedLimit = limit
        let task = Task { try await fetch(request, requestedOffset, requestedLimit) }
        self.task = task
        defer {
            if generation == epoch {
                isLoading = false; self.task = nil
            }
        }
        do {
            let page = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == epoch else { return }
            if requestedOffset == 0 {
                items = []; ids = []
            }
            let additions = page.filter { ids.insert($0.id).inserted }
            items.append(contentsOf: additions)
            // Advance by the wire count, never by the deduplicated item count.
            offset = request.expandsResults ? page.count : requestedOffset + page.count
            hasMore = page.count >= requestedLimit && !additions.isEmpty
            if request.expandsResults {
                // Doubling bounds cumulative transfer cost, unlike repeatedly adding
                // a fixed amount to a prefix query. Providers may impose their own limits.
                let (nextLimit, overflow) = requestedLimit.multipliedReportingOverflow(by: 2)
                if overflow {
                    hasMore = false
                } else {
                    limit = nextLimit
                }
            }
        } catch is CancellationError {}
        catch {
            if generation == epoch {
                self.error = error.localizedDescription
            }
        }
    }
}

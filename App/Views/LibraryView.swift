import MusicAssistantCore
import SwiftUI

/// iPhone and iPad library index, as in the system Music app: categories, then Recently Added.
/// Mac lists the same destinations in its sidebar.
struct LibraryHomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(LibraryCategory.index) { category in
                    CategoryRow(title: category.rawValue, symbol: category.symbol, route: .library(category))
                }
                CategoryRow(title: "Downloaded", symbol: "arrow.down.circle", route: .downloads, last: true)
                HStack(alignment: .firstTextBaseline) {
                    Text("Recently Added").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if model.albums.count > 6 {
                        NavigationLink("See All", value: Route.library(.recent))
                    }
                }
                .padding(.top, 28)
                .padding(.bottom, 12)
                recentAlbums
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .navigationTitle("Library")
        .navigationSubtitle(model.connection == .connected || model.isDemo ? "" : "Offline")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { model.showConnection = true }
                        .accessibilityIdentifier("settingsButton")
                }
            #endif
        }
        .refreshable { await model.loadLibrary() }
    }

    @ViewBuilder private var recentAlbums: some View {
        if let error = model.libraryError, model.albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { Task { await model.loadLibrary() } }
            }
        } else if model.albums.isEmpty {
            Group {
                if model.libraryLoading {
                    ProgressView()
                } else {
                    Text("No Albums").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(model.albums.prefix(12)) { AlbumCard(item: $0) }
            }
        }
    }
}

/// One full-width library category, styled as a list row.
private struct CategoryRow: View {
    let title: String
    let symbol: String
    let route: Route
    var last = false

    var body: some View {
        NavigationLink(value: route) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: symbol).foregroundStyle(.tint).frame(width: 28)
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.title3)
                .padding(.vertical, 12)
                .contentShape(.rect)
                if !last {
                    Divider().padding(.leading, 42)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-\(title)")
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let category: LibraryCategory
    @SceneStorage private var filter: String
    @SceneStorage private var sort: LibrarySort
    @State private var page = MediaPager()
    @State private var waitingForQuery = false
    @State private var loadGeneration = UUID()

    init(category: LibraryCategory) {
        self.category = category
        _filter = SceneStorage(wrappedValue: "", "libraryFilter.\(category.rawValue)")
        _sort = SceneStorage(wrappedValue: .library, "librarySort.\(category.rawValue)")
    }

    private enum LibrarySort: String, CaseIterable {
        case library = "Library Order", title = "Title", artist = "Artist"
    }

    private var collection: String {
        switch category {
        case .playlists: "playlists"
        case .songs: "tracks"
        case .artists: "artists"
        case .recent, .albums: "albums"
        }
    }

    private var cached: [MediaItem] {
        model.cachedLibraryItems(collection)
    }

    private var request: MediaPageRequest {
        let order: String = switch sort {
        case .library: category == .recent ? "timestamp_added_desc" : "sort_name"
        case .title: "sort_name"
        case .artist: category == .songs ? "track_artist_name" :
            category == .playlists || category == .artists ? "sort_name" : "album_artist_name"
        }
        return .library(
            collection: collection,
            search: filter.trimmingCharacters(in: .whitespacesAndNewlines),
            order: order
        )
    }

    private struct LoadIdentity: Equatable {
        let request: MediaPageRequest
        let server: URL?
        let connection: AppModel.Connection
    }

    private var loadIdentity: LoadIdentity {
        LoadIdentity(request: request, server: model.server?.baseURL, connection: model.connection)
    }

    private var isLoadingFirstPage: Bool {
        (page.isLoading || waitingForQuery) && page.items.isEmpty
    }

    private var isEmpty: Bool {
        page.items.isEmpty && page.error == nil && !page.hasMore && !waitingForQuery
    }

    private var canPaginate: Bool {
        model.connection == .connected && !model.isDemo && !waitingForQuery
    }

    var body: some View {
        content
            .overlay {
                if isLoadingFirstPage {
                    ProgressView()
                } else if isEmpty {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(category.rawValue)
            .navigationSubtitle(model.connection == .connected || model.isDemo ? "" : "Offline")
            .searchable(text: $filter, prompt: "Find in \(category.rawValue)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(
                                LibrarySort.allCases.filter {
                                    ![.playlists, .artists].contains(category) || $0 != .artist
                                },
                                id: \.self
                            ) { value in
                                Text(value == .library && category == .recent ? "Recently Added" : value.rawValue)
                                    .tag(value)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort")
                }
            }
            .task(id: loadIdentity) { await reload(debounce: true) }
            .onDisappear { page.suspend() }
            .refreshable { await reload() }
    }

    @ViewBuilder private var content: some View {
        if category == .songs {
            List {
                let songs = page.items
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, item in
                    MediaRow(item: item) { await model.play(songs, at: index) }
                        .onAppear { prefetch(near: item) }
                }
                footer.listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .top)],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(page.items) { item in
                        AlbumCard(item: item).onAppear { prefetch(near: item) }
                    }
                }
                footer.padding(.vertical, 16)
            }
            // Only the top and sides: the Mac window sets the bottom margin for its floating player.
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .contentMargins(.top, 16, for: .scrollContent)
        }
    }

    @ViewBuilder private var footer: some View {
        if !page.items.isEmpty {
            PaginationFooter(page: page, enabled: canPaginate) { await model.loadLibraryPage(page) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No \(category == .recent ? "Albums" : category.rawValue)", systemImage: category.symbol)
            } description: {
                if model.connection != .connected, !model.isDemo {
                    Text("Connect to your server to load your library.")
                }
            }
        }
    }

    private func prefetch(near item: MediaItem) {
        guard !waitingForQuery, page.items.count >= 10, item.id == page.items[page.items.count - 10].id,
              page.error == nil, page.request == request else { return }
        Task { await model.loadLibraryPage(page) }
    }

    private func reload(debounce: Bool = false) async {
        let attempt = UUID()
        loadGeneration = attempt
        waitingForQuery = true
        defer {
            if loadGeneration == attempt {
                waitingForQuery = false
            }
        }
        if model.connection != .connected || model.isDemo {
            if page.request == request, !page.items.isEmpty {
                page.suspend(); return
            }
            let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            var items = cached
                .filter { query.isEmpty || ($0.name + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }
            if sort == .title {
                items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            if sort == .artist {
                items.sort { $0.subtitle.localizedStandardCompare($1.subtitle) == .orderedAscending }
            }
            page.reset(cached: items)
            return
        }
        page.reset(request, cached: page.request == request ? page.items : [])
        if debounce {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        guard loadGeneration == attempt else { return }
        waitingForQuery = false
        await model.loadLibraryPage(page)
    }
}

/// Loads the next page when it scrolls into view. The button is an accessible fallback.
struct PaginationFooter: View {
    let page: MediaPager
    let enabled: Bool
    let load: () async -> Void
    var body: some View {
        VStack(spacing: 8) {
            if let error = page.error {
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }.disabled(!enabled || page.isLoading)
            } else if page.hasMore {
                if page.isLoading {
                    ProgressView()
                } else {
                    Button("Load More") { Task { await load() } }.disabled(!enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            if visible, enabled, page.error == nil {
                Task { await load() }
            }
        }
    }
}

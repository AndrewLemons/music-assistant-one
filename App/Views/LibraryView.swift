import MusicAssistantCore
import SwiftUI

/// iPhone and iPad library index. Mac lists the same destinations in its sidebar.
struct LibraryHomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(LibraryCategory.allCases.filter { $0 != .recent }) { category in
                    NavigationLink { LibraryView(category: category) } label: {
                        CategoryLabel(category.rawValue, symbol: category.symbol)
                    }
                }
                NavigationLink { DownloadsView() } label: {
                    CategoryLabel("Downloaded", symbol: "arrow.down.circle")
                }
            }
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Recently Added").font(.title2.bold())
                    Spacer()
                    if !model.albums.isEmpty {
                        NavigationLink("See All") { LibraryView(category: .recent) }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .foregroundStyle(.tint)
                            .fixedSize()
                    }
                }
                .padding(.top, 20)
                .listRowSeparator(.hidden)
                recentAlbums
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { model.showConnection = true }
                    .accessibilityIdentifier("settingsButton")
            }
        }
        .refreshable { await model.loadLibrary() }
    }

    @ViewBuilder private var recentAlbums: some View {
        if let error = model.libraryError {
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
                ForEach(model.albums.prefix(6)) { AlbumCard(item: $0) }
            }
        }
    }
}

private struct CategoryLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .font(.title3)
        .padding(.vertical, 6)
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
        case .artist: category == .songs ? "track_artist_name" : category == .playlists ? "sort_name" : "album_artist_name"
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
                                LibrarySort.allCases.filter { category != .playlists || $0 != .artist },
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
                ForEach(page.items) { item in
                    MediaRow(item: item).onAppear { prefetch(near: item) }
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

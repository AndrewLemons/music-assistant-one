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
    /// Remembered per category across launches.
    @AppStorage private var storedSort: LibrarySort
    @State private var page = MediaPager()
    @State private var waitingForQuery = false
    @State private var loadGeneration = UUID()

    init(category: LibraryCategory) {
        self.category = category
        _filter = SceneStorage(wrappedValue: "", "libraryFilter.\(category.rawValue)")
        _storedSort = AppStorage(wrappedValue: .default, "librarySort.\(category.rawValue)")
    }

    /// Recently Added is defined by its order, so it has no sort menu.
    private var sort: LibrarySort {
        category == .recent ? LibrarySort(.dateAdded) : storedSort.supported(by: collection)
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

    /// Filtering and sorting happen on the server, before pagination.
    private var request: MediaPageRequest {
        .library(
            collection: collection,
            search: filter.trimmingCharacters(in: .whitespacesAndNewlines),
            order: sort.orderKey(for: collection)
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
                if category != .recent {
                    ToolbarItem(placement: .primaryAction) { sortMenu }
                }
            }
            .task(id: loadIdentity) { await reload(debounce: true) }
            .onDisappear { page.suspend() }
            .refreshable { await reload() }
    }

    /// Sort fields and, where it applies, direction. Choosing a field starts in its usual direction.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding { sort.field } set: { storedSort = LibrarySort($0) }) {
                ForEach(LibrarySort.fields(for: collection), id: \.self) { field in
                    Text(title(for: field)).tag(field)
                }
            }
            .pickerStyle(.inline)
            if sort.field.hasDirection {
                Picker("Order", selection: Binding { sort.ascending } set: {
                    storedSort = LibrarySort(sort.field, ascending: $0)
                }) {
                    let (ascending, descending) = directions(for: sort.field)
                    Text(ascending).tag(true)
                    Text(descending).tag(false)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("Sort")
        .accessibilityIdentifier("sortMenu")
    }

    private func title(for field: LibrarySort.Field) -> String {
        switch field {
        case .title: category == .artists ? "Name" : "Title"
        case .artist: "Artist"
        case .dateAdded: "Date Added"
        case .year: "Year"
        case .duration: "Duration"
        case .mostPlayed: "Most Played"
        case .recentlyPlayed: "Recently Played"
        }
    }

    private func directions(for field: LibrarySort.Field) -> (ascending: String, descending: String) {
        switch field {
        case .dateAdded, .year: ("Oldest First", "Newest First")
        case .duration: ("Shortest First", "Longest First")
        default: ("A to Z", "Z to A")
        }
    }

    @ViewBuilder private var content: some View {
        if category == .songs {
            List {
                let songs = page.items
                if !songs.isEmpty {
                    // The whole list as shown, including songs not loaded yet.
                    PlayShuffleButtons {
                        await model.playLibrary(page)
                    } shuffle: {
                        await model.playLibrary(page, shuffled: true)
                    }
                    .disabled(!songs.contains(where: model.canPlay))
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, item in
                    MediaRow(item: item) { await model.playLibrary(page, at: index) }
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
            // Offline, the cache is filtered and ordered locally, as closely as its metadata allows.
            let items = cached
                .filter { query.isEmpty || ($0.name + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }
            page.reset(cached: sort.sorted(items))
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

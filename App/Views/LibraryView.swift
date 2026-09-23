import SwiftUI
import MusicAssistantCore

struct LibraryHomeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                ForEach(LibraryCategory.allCases) { category in
                    NavigationLink {
                        LibraryView(category: category)
                    } label: {
                        Label(category.rawValue, systemImage: category.symbol)
                            .font(.title3).padding(.vertical, 5)
                    }
                }
            }
            Section("Recently Added") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18, alignment: .top)], spacing: 24) {
                    ForEach(model.albums.prefix(6)) { AlbumCard(item: $0) }
                }.padding(.vertical, 8)
                if model.libraryLoading { ProgressView("Loading your library…") }
                if let error = model.libraryError {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.loadLibrary() } }
                } else if model.albums.isEmpty && !model.libraryLoading {
                    Text("Albums you add in Music Assistant appear here.").foregroundStyle(.secondary)
                }
            }.listRowBackground(Color.clear)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showConnection = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Connection settings")
            }
        }
        .refreshable { await model.loadLibrary() }
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
    private var cached: [MediaItem] { model.cachedLibraryItems(collection) }
    private var request: MediaPageRequest {
        let order: String
        switch sort {
        case .library: order = category == .recent ? "timestamp_added_desc" : "sort_name"
        case .title: order = "sort_name"
        case .artist: order = category == .songs ? "track_artist_name" : category == .playlists ? "sort_name" : "album_artist_name"
        }
        return .library(collection: collection, search: filter.trimmingCharacters(in: .whitespacesAndNewlines), order: order)
    }
    private struct LoadIdentity: Equatable {
        let request: MediaPageRequest
        let server: URL?
        let connection: AppModel.Connection
    }
    private var loadIdentity: LoadIdentity {
        LoadIdentity(request: request, server: model.server?.baseURL, connection: model.connection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("\(page.items.count) loaded")
                    Spacer()
                    if model.isDemo { Label("Preview", systemImage: "eye") }
                    else if model.connection != .connected { Text("Saved library · Offline") }
                }.font(.subheadline).foregroundStyle(.secondary)

                if (page.isLoading || waitingForQuery) && page.items.isEmpty {
                    ProgressView("Loading your library…").frame(maxWidth: .infinity).padding(60)
                } else if page.items.isEmpty && page.error == nil && !page.hasMore && !waitingForQuery {
                    ContentUnavailableView(filter.isEmpty ? "Your music belongs here" : "No Matches",
                        systemImage: category.symbol,
                        description: Text(model.connection == .connected ? "Try another search or add music to your library." : "Only previously loaded library items are available offline."))
                }
                if category == .songs {
                    LazyVStack(spacing: 0) {
                        ForEach(page.items) { item in
                            MediaRow(item: item)
                                .onAppear { prefetch(near: item) }
                            Divider().padding(.leading, 60)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                        ForEach(page.items) { item in
                            AlbumCard(item: item).onAppear { prefetch(near: item) }
                        }
                    }
                }
                PaginationFooter(page: page, enabled: model.connection == .connected && !model.isDemo && !waitingForQuery) {
                    await model.loadLibraryPage(page)
                }
            }.padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(category.rawValue)
        .searchable(text: $filter, prompt: "Find in \(category.rawValue)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(LibrarySort.allCases.filter { category != .playlists || $0 != .artist }, id: \.self) { value in
                            Text(value == .library && category == .recent ? "Recently Added" : value.rawValue).tag(value)
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort library")
            }
        }
        .task(id: loadIdentity) { await reload(debounce: true) }
        .onDisappear { page.suspend() }
        .refreshable { await reload() }
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
        defer { if loadGeneration == attempt { waitingForQuery = false } }
        if model.connection != .connected || model.isDemo {
            if page.request == request && !page.items.isEmpty { page.suspend(); return }
            let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            var items = cached.filter { query.isEmpty || ($0.name + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }
            if sort == .title { items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            if sort == .artist { items.sort { $0.subtitle.localizedStandardCompare($1.subtitle) == .orderedAscending } }
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

/// The explicit button doubles as an accessible fallback. Visibility, rather than
/// eager view construction, drives automatic loading at the end of a scroll view.
struct PaginationFooter: View {
    let page: MediaPager
    let enabled: Bool
    let load: () async -> Void
    var body: some View {
        VStack(spacing: 8) {
            if let error = page.error { Text(error).font(.callout).foregroundStyle(.secondary) }
            if page.hasMore {
                HStack {
                    if page.isLoading { ProgressView().controlSize(.small) }
                    Button(page.error == nil ? "Load More" : "Try Again") { Task { await load() } }
                        .disabled(!enabled || page.isLoading)
                }
            } else if !page.items.isEmpty && enabled {
                Text("All available results loaded").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            if visible && enabled && page.error == nil { Task { await load() } }
        }
    }
}

struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem?
    var cornerRadius: CGFloat = 10
    var body: some View {
        AsyncImage(url: item?.artworkURL(server: model.server)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            GeometryReader { geometry in
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: item?.kind == "playlist" ? "music.note.list" : "music.note")
                            .font(.system(size: max(14, geometry.size.width * 0.32), weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    let item: MediaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { Task { await model.play(item) } } label: {
                ArtworkView(item: item, cornerRadius: 7)
                    .overlay(alignment: .bottomTrailing) {
                        if hovering {
                            Image(systemName: "play.fill")
                                .font(.title3).foregroundStyle(.white)
                                .padding(12).background(.black.opacity(0.6), in: Circle())
                                .padding(10).accessibilityHidden(true)
                        }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.06)) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(item.name), \(item.subtitle)")
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(2)
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu { MediaActions(item: item) } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More options for \(item.name)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { MediaActions(item: item) }
    }
}

struct MediaRow: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await model.play(item) } } label: {
                HStack(spacing: 12) {
                    ArtworkView(item: item, cornerRadius: 7).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).foregroundStyle(.primary).lineLimit(1)
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if item.duration > 0 { Text(formatTime(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Play \(item.name), \(item.subtitle)")
                .accessibilityIdentifier("media-\(item.kind)-\(item.name)")
            Menu { MediaActions(item: item) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options for \(item.name)")
        }.padding(.vertical, 8)
        .contextMenu { MediaActions(item: item) }
    }
}

struct MediaActions: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        Button("Play", systemImage: "play.fill") { Task { await model.play(item) } }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { Task { await model.play(item, option: "next") } }
        Button("Add to Queue", systemImage: "text.badge.plus") { Task { await model.play(item, option: "add") } }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let value = Int(max(0, seconds))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
}

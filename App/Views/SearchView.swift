import MusicAssistantCore
import SwiftUI

struct SearchView: View {
    static let prompt: LocalizedStringKey = "Artists, Songs, Albums, and More"
    @Environment(AppModel.self) private var model
    @SceneStorage("searchCategory") private var filter = SearchFilter.all
    @FocusState private var searchFocused: Bool

    /// Results per category in the combined view; See All shows the rest.
    private let previewLimit = 5

    private enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists", radio = "Radio"
        var id: Self {
            self
        }

        var kind: String {
            switch self {
            case .all: ""
            case .songs: "track"
            case .albums: "album"
            case .artists: "artist"
            case .playlists: "playlist"
            case .radio: "radio"
            }
        }

        var symbol: String {
            switch self {
            case .all: "magnifyingglass"
            case .songs: "music.note"
            case .albums: "square.stack"
            case .artists: "music.mic"
            case .playlists: "music.note.list"
            case .radio: "dot.radiowaves.left.and.right"
            }
        }

        var color: Color {
            switch self {
            case .all: .gray
            case .songs: .pink
            case .albums: .orange
            case .artists: .purple
            case .playlists: .blue
            case .radio: .teal
            }
        }
    }

    private var query: String {
        model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sections: [SearchFilter] {
        SearchFilter.allCases.filter { $0 != .all && (filter == .all || $0 == filter) }
    }

    private var hasNoResults: Bool {
        !model.searchDebouncing && sections.allSatisfy { section in
            guard let page = model.searchPages[section.kind] else { return false }
            return page.items.isEmpty && !page.isLoading && !page.hasMore && page.error == nil
        }
    }

    private var isSearching: Bool {
        sections.allSatisfy { model.searchPages[$0.kind]?.items.isEmpty ?? true } &&
            (model.searchDebouncing || sections.contains { model.searchPages[$0.kind]?.isLoading == true })
    }

    private struct SearchIdentity: Equatable {
        let query: String
        let server: URL?
        let connection: AppModel.Connection
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if query.isEmpty {
                browse
            } else {
                VStack(spacing: 0) {
                    filters
                    results
                        .overlay {
                            if isSearching {
                                ProgressView()
                            } else if hasNoResults {
                                noResults
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search")
        .navigationSubtitle(model.connection == .connected ? "" : "Offline")
        #if os(iOS)
            // The search tab doesn't present its own field on every release; keep one visible.
            .searchable(
                text: $model.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Self.prompt
            )
        #else
            .searchable(text: $model.searchText, prompt: Self.prompt)
        #endif
            .searchFocused($searchFocused)
            .task(id: SearchIdentity(query: query, server: model.server?.baseURL, connection: model.connection)) {
                await model.search()
            }
            .onDisappear {
                for page in model.searchPages.values {
                    page.suspend()
                }
            }
    }

    // MARK: Results

    private var results: some View {
        List {
            ForEach(sections) { section in
                if let page = model.searchPages[section.kind], !page.items.isEmpty || filter != .all {
                    Section {
                        let items = filter == .all ? Array(page.items.prefix(previewLimit)) : page.items
                        ForEach(items) { item in
                            MediaRow(item: item).onAppear { prefetch(item, in: page, kind: section.kind) }
                        }
                        if filter != .all {
                            PaginationFooter(
                                page: page,
                                enabled: model.connection == .connected && !model.isDemo && !model.searchDebouncing
                            ) {
                                await model.loadSearchPage(section.kind)
                            }
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        if filter == .all {
                            HStack {
                                Text(section.rawValue)
                                Spacer()
                                if page.items.count > previewLimit || page.hasMore {
                                    Button("See All") { filter = section }
                                        .font(.subheadline)
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("See All \(section.rawValue)")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder private var noResults: some View {
        if filter == .all {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView {
                Label("No \(filter.rawValue)", systemImage: filter.symbol)
            } description: {
                Text("No \(filter.rawValue.lowercased()) match “\(query)”.")
            } actions: {
                Button("Show All Results") { filter = .all }
            }
        }
    }

    private func prefetch(_ item: MediaItem, in page: MediaPager, kind: String) {
        guard filter != .all, page.items.count >= 5, item.id == page.items[page.items.count - 5].id,
              page.error == nil else { return }
        Task { await model.loadSearchPage(kind) }
    }

    // MARK: Filters

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { value in
                    let selected = filter == value
                    Button(value.rawValue) { filter = value }
                        .font(.subheadline.weight(.medium))
                        .buttonBorderShape(.capsule)
                        .tint(selected ? Color.accentColor : Color.primary)
                        .modifier(ChipStyle(selected: selected))
                        .accessibilityIdentifier("filter-\(value.rawValue)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        #if os(macOS)
            // The floating player's bottom margin belongs to results, not this strip.
            .contentMargins(.bottom, 0)
        #endif
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Categories")
    }

    // MARK: Browse

    private var browse: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(SearchFilter.allCases.filter { $0 != .all }) { category in
                    Button {
                        filter = category
                        searchFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(category.color.gradient, in: .circle)
                            Text(category.rawValue).font(.headline).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                        .contentShape(.rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search \(category.rawValue)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

/// Selected chips are filled; others are bordered.
private struct ChipStyle: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

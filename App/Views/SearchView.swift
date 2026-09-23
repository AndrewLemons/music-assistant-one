import SwiftUI
import MusicAssistantCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("searchCategory") private var filter = SearchFilter.all
    @FocusState private var searchFocused: Bool

    private enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists", radio = "Radio"
        var id: Self { self }
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
    }
    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [MediaItem] {
        model.searchResults.filter { filter == .all || $0.kind == filter.kind }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            filters
            Divider()
            Group {
                if query.isEmpty {
                    discovery
                } else if model.searching {
                    ProgressView("Searching your music…")
                } else if let error = model.searchError {
                    ContentUnavailableView {
                        Label("Search Unavailable", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await model.search() } }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView {
                        Label(filter == .all ? "No Results" : "No \(filter.rawValue) Found", systemImage: "magnifyingglass")
                    } description: {
                        Text("No matches for “\(query)”. Try a different search\(filter == .all ? "." : " or another category.")")
                    } actions: {
                        if filter != .all { Button("Show All Results") { filter = .all } }
                    }
                } else {
                    List {
                        ForEach(SearchFilter.allCases.filter { $0 != .all }) { section in
                            let items = results.filter { $0.kind == section.kind }
                            if !items.isEmpty {
                                Section {
                                    ForEach(items) { item in MediaRow(item: item) }
                                } header: {
                                    HStack {
                                        Text(section.rawValue)
                                        Spacer()
                                        Text("\(items.count)").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }.listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search")
        #if os(macOS)
        .searchable(text: $model.searchText, prompt: "Search your music services")
        #else
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your music services")
        #endif
        .searchFocused($searchFocused)
        .task(id: model.searchText) { await model.search() }
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { value in
                    Button { filter = value } label: {
                        Text(value.rawValue)
                            .font(.subheadline.weight(filter == value ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(filter == value ? Color.accentColor : .secondary)
                            .background(filter == value ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter: \(value.rawValue)")
                    .accessibilityAddTraits(filter == value ? .isSelected : [])
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var discovery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find your next favorite").font(.largeTitle.bold())
                    Text("All your music services. One place to search.")
                        .font(.title3).foregroundStyle(.secondary)
                }.padding(.top, 16)
                Text("Explore Your Music").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(SearchFilter.allCases.filter { $0 != .all }) { category in
                        Button {
                            filter = category
                            searchFocused = true
                        } label: {
                            VStack(alignment: .leading, spacing: 24) {
                                Image(systemName: category.symbol).font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(.tint)
                                HStack {
                                    Text(category.rawValue).font(.headline).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                            .contentShape(.rect(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel("Search \(category.rawValue.lowercased())")
                    }
                }
                Text("Results come from the providers connected to Music Assistant.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}

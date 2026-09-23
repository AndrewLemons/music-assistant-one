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

    init(category: LibraryCategory) {
        self.category = category
        _filter = SceneStorage(wrappedValue: "", "libraryFilter.\(category.rawValue)")
        _sort = SceneStorage(wrappedValue: .library, "librarySort.\(category.rawValue)")
    }

    private enum LibrarySort: String, CaseIterable {
        case library = "Library Order", title = "Title", artist = "Artist"
    }
    private var source: [MediaItem] {
        switch category {
        case .playlists: model.playlists
        case .songs: model.tracks
        case .recent, .albums: model.albums
        }
    }
    private var items: [MediaItem] {
        let matches = source.filter { filter.isEmpty || ($0.name + " " + $0.subtitle).localizedStandardContains(filter) }
        switch sort {
        case .library: return matches
        case .title: return matches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .artist: return matches.sorted { $0.subtitle.localizedStandardCompare($1.subtitle) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(category == .recent ? "The latest in your library" : "\(source.count) \(category.rawValue.lowercased())")
                    Spacer()
                    if model.isDemo { Label("Preview", systemImage: "eye") }
                }.font(.subheadline).foregroundStyle(.secondary)

                if let error = model.libraryError, !source.isEmpty {
                    Label(error, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.loadLibrary() } }
                }
                if model.libraryLoading && source.isEmpty {
                    ProgressView("Loading your library…").frame(maxWidth: .infinity).padding(60)
                } else if let error = model.libraryError, source.isEmpty {
                    ContentUnavailableView {
                        Label("Library Unavailable", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await model.loadLibrary() } }
                    }
                } else if source.isEmpty {
                    ContentUnavailableView("Your music belongs here", systemImage: category.symbol,
                        description: Text("Music you add to your Music Assistant library appears here. Search your services to find something to play."))
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else if category == .songs {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            MediaRow(item: item)
                            Divider().padding(.leading, 60)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                        ForEach(items) { AlbumCard(item: $0) }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(category.rawValue)
        .searchable(text: $filter, prompt: "Find in \(category.rawValue)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(LibrarySort.allCases, id: \.self) { value in
                            Text(value == .library && category == .recent ? "Recently Added" : value.rawValue).tag(value)
                        }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort library")
                .help("Sort \(category.rawValue.lowercased())")
            }
        }
        .refreshable { await model.loadLibrary() }
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

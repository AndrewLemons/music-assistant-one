import MusicAssistantCore
import SwiftUI

/// Music Assistant's home rows as horizontal shelves. Offline, downloaded music fills it.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var offlineCollections: [MediaItem] {
        model.downloads.collections.map { MediaItem($0.metadata) }
            .filter { model.canPlay($0) }
    }

    private var isOffline: Bool {
        model.connection != .connected && !model.isDemo
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if isOffline, !offlineCollections.isEmpty {
                    Shelf(title: "Downloaded", items: offlineCollections, seeAll: .downloads)
                }
                ForEach(shelves) { shelf in
                    Shelf(title: shelf.title, items: shelf.items)
                }
            }
            .padding(.vertical, 12)
        }
        .overlay {
            if shelves.isEmpty, !(isOffline && !offlineCollections.isEmpty) {
                if model.homeLoading || model.libraryLoading {
                    ProgressView()
                } else if isOffline {
                    ContentUnavailableView(
                        "Offline",
                        systemImage: "wifi.slash",
                        description: Text("Downloaded music plays without a connection.")
                    )
                } else {
                    ContentUnavailableView(
                        "Nothing Here Yet",
                        systemImage: "music.note.house",
                        description: Text("Music you add and play appears here.")
                    )
                }
            }
        }
        .navigationTitle("Home")
        .navigationSubtitle(isOffline ? "Offline" : "")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { model.showConnection = true }
                        .accessibilityIdentifier("settingsButton")
                }
            #endif
        }
        .refreshable { await model.loadHome() }
    }

    /// Demo mode and servers without home rows still show recently added albums.
    private var shelves: [AppModel.HomeShelf] {
        if !model.homeShelves.isEmpty {
            return model.homeShelves
        }
        guard !model.albums.isEmpty else { return [] }
        return [AppModel.HomeShelf(id: "recent", title: "Recently Added", items: Array(model.albums.prefix(20)))]
    }
}

/// A titled, horizontally scrolling row of cards. Its title opens every item when there are more.
struct Shelf: View {
    let title: String
    let items: [MediaItem]
    var seeAll: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        AlbumCard(item: item).frame(width: 156)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }

    @ViewBuilder private var header: some View {
        let route = seeAll ?? (items.count > 4 ? Route.shelf(title, items) : nil)
        Group {
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.forward").foregroundStyle(.secondary).imageScale(.small)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows all")
            } else {
                Text(title)
            }
        }
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 20)
    }
}

/// Every item in a shelf, as a grid.
struct ShelfGridView: View {
    let title: String
    let items: [MediaItem]
    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(items) { AlbumCard(item: $0) }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .contentMargins(.top, 16, for: .scrollContent)
        .navigationTitle(title)
    }
}

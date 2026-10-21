import MusicAssistantCore
import SwiftUI

/// Pages pushed onto a navigation stack. Each tap pushes exactly one value, so a card
/// opens only the item it shows and Back returns to the page it came from.
enum Route: Hashable {
    case collection(MediaItem)
    case artist(MediaItem)
    case library(LibraryCategory)
    case downloads
    case shelf(String, [MediaItem])

    static func page(for item: MediaItem) -> Route? {
        if item.isCollection {
            return .collection(item)
        }
        return item.kind == "artist" ? .artist(item) : nil
    }
}

extension MediaItem: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uri)
    }
}

enum AppTab: Hashable { case home, library, search }

/// Per-tab stacks, so other screens can open an album or artist where the listener is.
@MainActor @Observable
final class Router {
    var tab = AppTab.home
    var paths: [AppTab: NavigationPath] = [:]

    func path(_ tab: AppTab) -> Binding<NavigationPath> {
        Binding { self.paths[tab] ?? NavigationPath() } set: { self.paths[tab] = $0 }
    }

    /// Opens a page in the visible tab, as Go to Album does from Now Playing.
    func open(_ route: Route) {
        paths[tab, default: NavigationPath()].append(route)
    }

    /// Choosing the selected tab again returns to its first page.
    func select(_ tab: AppTab) {
        if self.tab == tab {
            paths[tab] = NavigationPath()
        }
        self.tab = tab
    }
}

extension View {
    /// Registers every page a stack can push. Apply once to each stack's root view.
    func musicDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .collection(item): CollectionDetailView(item: item)
            case let .artist(item): ArtistDetailView(item: item)
            case let .library(category): LibraryView(category: category)
            case .downloads: DownloadsView()
            case let .shelf(title, items): ShelfGridView(title: title, items: items)
            }
        }
    }
}

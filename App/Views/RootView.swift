import SwiftUI

enum LibraryCategory: String, CaseIterable, Identifiable {
    case recent = "Recently Added", playlists = "Playlists", artists = "Artists", albums = "Albums", songs = "Songs"
    var id: Self {
        self
    }

    /// The library index order of the system Music app.
    static let index: [LibraryCategory] = [.playlists, .artists, .albums, .songs]

    var symbol: String {
        switch self {
        case .recent: "clock"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        }
    }
}

enum Destination: Hashable {
    case home, library(LibraryCategory), search, players, downloads
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
        @State private var selection: Destination? = .home
        @State private var detailFrame = CGRect.zero
        @State private var playerHeight: CGFloat = 80
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.hasSavedSession, model.connection == .disconnected || model.connection == .connecting {
                OnboardingView()
            } else {
                #if os(macOS)
                    if model.showNowPlaying {
                        NowPlayingView()
                    } else {
                        desktopBrowser
                    }
                #else
                    // Speakers are chosen from the player, as in Music Assistant's own mobile layout.
                    TabView(selection: Binding(get: { model.router.tab }, set: { model.router.select($0) })) {
                        Tab("Home", systemImage: "music.note.house", value: AppTab.home) {
                            NavigationStack(path: model.router.path(.home)) { HomeView().musicDestinations() }
                        }
                        Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                            NavigationStack(path: model.router.path(.library)) {
                                LibraryHomeView().musicDestinations()
                            }
                        }
                        Tab(value: AppTab.search, role: .search) {
                            NavigationStack(path: model.router.path(.search)) { SearchView().musicDestinations() }
                        }
                    }
                    .tabViewStyle(.sidebarAdaptable)
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory { MiniPlayer() }
                    .sheet(isPresented: $model.showNowPlaying) { NowPlayingView() }
                    .sheet(isPresented: $model.showConnection) { SettingsView() }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.connection == .reconnecting {
                OfflineBanner()
            }
        }
        .animation(.default, value: model.connection == .reconnecting)
        .sheet(isPresented: $model.showPlayers) {
            NavigationStack { PlayersView(isSheet: true) }.presentationDetents([.medium, .large])
        }
        .modifier(PlaylistPresentation())
        .alert(
            model.error ?? "",
            isPresented: Binding(get: { model.error != nil }, set: {
                if !$0 {
                    model.error = nil
                }
            })
        ) {
            Button("OK") { model.error = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refreshAfterForeground() }
            }
        }
        #if os(macOS)
        .onChange(of: model.showConnection) { _, show in
            guard show else { return }
            model.showConnection = false
            openSettings()
        }
        #endif
    }

    #if os(macOS)
        private var desktopBrowser: some View {
            NavigationSplitView {
                List(selection: $selection) {
                    Label("Home", systemImage: "music.note.house").tag(Destination.home)
                    Label("Search", systemImage: "magnifyingglass").tag(Destination.search)
                    Label("Players", systemImage: "hifispeaker.2").tag(Destination.players)
                    Section("Library") {
                        ForEach([LibraryCategory.recent] + LibraryCategory.index) { category in
                            Label(category.rawValue, systemImage: category.symbol).tag(Destination.library(category))
                        }
                        Label("Downloaded", systemImage: "arrow.down.circle").tag(Destination.downloads)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ServerButton { model.showConnection = true }.padding(10)
                }
            } detail: {
                NavigationStack(path: model.router.path(.home)) {
                    Group {
                        switch selection ?? .home {
                        case .home: HomeView()
                        case let .library(category): LibraryView(category: category).id(category)
                        case .search: SearchView()
                        case .players: PlayersView()
                        case .downloads: DownloadsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .musicDestinations()
                }
                .onChange(of: selection) { model.router.paths[.home] = NavigationPath() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.windowSpace)) } action: {
                    detailFrame = $0
                }
            }
            // Leave room to scroll the last row above the floating player without
            // shrinking the viewport. Set here so pushed pages inherit it too.
            .contentMargins(.bottom, playerHeight)
            // Pushing a page replaces the detail column's view hierarchy on macOS, which
            // would remove a player attached there. The window owns it instead.
            .overlay(alignment: .bottomLeading) {
                MiniPlayer()
                    .padding(.horizontal, 14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { playerHeight = $0 }
                    .frame(width: max(0, detailFrame.width))
                    .offset(x: detailFrame.minX)
            }
            .coordinateSpace(.named(Self.windowSpace))
        }

        private static let windowSpace = "window"
    #endif
}

/// Shown while the saved session reconnects. Downloaded music keeps playing.
private struct OfflineBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 12) {
            Label("Offline", systemImage: "wifi.slash")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Retry") { model.retryConnection() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

#if os(macOS)
    /// The sidebar's server status. Opens Settings.
    private struct ServerButton: View {
        @Environment(AppModel.self) private var model
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.serverName).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityValue("\(model.serverName), \(status)")
            .accessibilityIdentifier("settingsButton")
            .help("Settings")
        }

        private var status: String {
            model.isDemo ? "Sample Library" : model.connection == .connected ? "Connected" : "Offline"
        }
    }
#endif

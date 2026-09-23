import SwiftUI

enum LibraryCategory: String, CaseIterable, Identifiable {
    case recent = "Recently Added", albums = "Albums", songs = "Songs", playlists = "Playlists"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .recent: "clock"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        }
    }
}

enum Destination: Hashable {
    case library(LibraryCategory), search, players
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Destination? = .library(.recent)
    #if os(macOS)
    @State private var playerOverlayHeight: CGFloat = 80
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.hasSavedSession && (model.connection == .disconnected || model.connection == .connecting) {
                OnboardingView()
            } else {
                #if os(macOS)
                if model.showNowPlaying {
                    NowPlayingView()
                } else {
                    desktopBrowser
                }
                #else
                TabView {
                    Tab("Library", systemImage: "music.note.house") { NavigationStack { LibraryHomeView() } }
                    Tab("Players", systemImage: "hifispeaker.2") { NavigationStack { PlayersView() } }
                    Tab(role: .search) { NavigationStack { SearchView() } }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabViewBottomAccessory { MiniPlayer().padding(.horizontal, 12) }
                .sheet(isPresented: $model.showNowPlaying) { NowPlayingView() }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if model.connection == .reconnecting {
                HStack {
                    Label("Offline · Reconnecting…", systemImage: "wifi.exclamationmark")
                    Button("Retry") { model.retryConnection() }
                    Button("Settings") { model.showConnection = true }
                }.font(.callout).padding().glassEffect().padding()
            }
        }
        .sheet(isPresented: $model.showPlayers) {
            NavigationStack { PlayersView(isSheet: true) }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.showConnection) { ConnectionSettings() }
        .alert("Music Assistant", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAfterForeground() } }
        }
    }

    #if os(macOS)
    private var desktopBrowser: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Search", systemImage: "magnifyingglass").tag(Destination.search)
                }
                Section("Library") {
                    ForEach(LibraryCategory.allCases) { category in
                        Label(category.rawValue, systemImage: category.symbol).tag(Destination.library(category))
                    }
                }
                Section("Listen On") {
                    Label("Players", systemImage: "hifispeaker.2").tag(Destination.players)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Music")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    connectionButton.padding(12)
                }
            }
        } detail: {
            NavigationStack {
                Group {
                    switch selection ?? .library(.recent) {
                    case .library(let category): LibraryView(category: category).id(category)
                    case .search: SearchView()
                    case .players: PlayersView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Leave room to scroll the last row above the floating player
                // without shrinking the viewport or drawing a bottom shelf.
                .contentMargins(.bottom, playerOverlayHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .overlay(alignment: .bottom) {
                MiniPlayer()
                    .padding(.horizontal, 14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        playerOverlayHeight = height
                    }
            }
        }
    }
    #endif

    private var connectionButton: some View {
        Button { model.showConnection = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection").font(.subheadline.weight(.medium))
                    Text(model.isDemo ? "Interface preview" : model.serverName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection settings")
        .help("Manage your Music Assistant connection")
    }
}

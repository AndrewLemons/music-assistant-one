import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case library = "Library", search = "Search", players = "Players"
    var id: Self { self }
    var symbol: String { switch self { case .library: "music.note.house"; case .search: "magnifyingglass"; case .players: "hifispeaker.2" } }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Destination? = .library
    var body: some View {
        @Bindable var model = model
        Group {
            if model.connection == .disconnected || model.connection == .connecting {
                OnboardingView()
            } else {
                #if os(macOS)
                NavigationSplitView {
                    List(Destination.allCases, selection: $selection) { destination in
                        Label(destination.rawValue, systemImage: destination.symbol).tag(destination)
                    }
                    .navigationTitle("Music")
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                    .safeAreaInset(edge: .bottom) { connectionBadge.padding() }
                } detail: {
                    NavigationStack { content(selection ?? .library) }
                        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer().padding(12).glassEffect(.regular, in: .rect(cornerRadius: 20)).padding(12) }
                }
                #else
                TabView {
                    Tab("Library", systemImage: "music.note.house") { NavigationStack { LibraryView() } }
                    Tab("Players", systemImage: "hifispeaker.2") { NavigationStack { PlayersView() } }
                    Tab(role: .search) { NavigationStack { SearchView() } }
                }
                .tabViewStyle(.sidebarAdaptable)
                .tabViewBottomAccessory { MiniPlayer().padding(.horizontal, 12) }
                #endif
            }
        }
        .overlay(alignment: .top) {
            if model.connection == .reconnecting {
                Label("Reconnecting to Music Assistant…", systemImage: "wifi.exclamationmark")
                    .font(.callout).padding().glassEffect().padding()
            }
        }
        .sheet(isPresented: $model.showNowPlaying) { NowPlayingView() }
        .sheet(isPresented: $model.showPlayers) { NavigationStack { PlayersView(isSheet: true) }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $model.showConnection) { ConnectionSettings() }
        .alert("Music Assistant", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAfterForeground() } }
        }
    }
    @ViewBuilder private func content(_ destination: Destination) -> some View {
        switch destination {
        case .library: LibraryView()
        case .search: SearchView()
        case .players: PlayersView()
        }
    }
    private var connectionBadge: some View {
        Button { model.showConnection = true } label: {
            HStack {
                Image(systemName: model.isDemo ? "eye" : "network").foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(model.isDemo ? "Interface preview" : model.serverName).font(.subheadline.weight(.medium))
                    Text(model.isDemo ? "Connect to play music" : "Connected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }.buttonStyle(.plain)
    }
}

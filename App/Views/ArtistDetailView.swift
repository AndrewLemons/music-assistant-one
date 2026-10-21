import MusicAssistantCore
import SwiftUI

/// An artist's top songs and releases, as in the system Music app.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var songs: [MediaItem] = []
    @State private var albums: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showsAllSongs = false

    private var visibleSongs: [MediaItem] {
        showsAllSongs ? songs : Array(songs.prefix(5))
    }

    private func releases(_ types: Set<String>) -> [MediaItem] {
        albums.filter { types.contains($0.albumType) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if loading, songs.isEmpty, albums.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                }
                if !songs.isEmpty {
                    topSongs
                }
                let full = releases(["album", "unknown"])
                if !full.isEmpty {
                    Shelf(title: "Albums", items: full)
                }
                let singles = releases(["single", "ep"])
                if !singles.isEmpty {
                    Shelf(title: "Singles & EPs", items: singles)
                }
                let compilations = releases(["compilation", "live", "soundtrack"])
                if !compilations.isEmpty {
                    Shelf(title: "Compilations", items: compilations)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(item.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu { MediaActions(item: item) } label: { Label("More", systemImage: "ellipsis") }
                        .accessibilityLabel("More options for \(item.name)")
                }
            }
            .environment(\.currentPage, item.uri)
            .task(id: item.uri) { await load() }
            .refreshable { await load() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            ArtworkView(item: item).frame(maxWidth: 220)
                .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
            Text(item.name).font(.title.bold()).multilineTextAlignment(.center)
            PlayShuffleButtons {
                await model.play(item, shuffled: false)
            } shuffle: {
                await model.play(item, shuffled: true)
            }
            .disabled(!model.canPlay(item) || (songs.isEmpty && !loading))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var topSongs: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Top Songs").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if songs.count > 5 {
                    Button(showsAllSongs ? "Show Less" : "See All") {
                        withAnimation { showsAllSongs.toggle() }
                    }
                    .font(.subheadline)
                }
            }
            ForEach(Array(visibleSongs.enumerated()), id: \.offset) { index, song in
                MediaRow(item: song) { await model.play(songs, at: index) }
                if index < visibleSongs.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { (songs, albums) = try await model.artistContent(item) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

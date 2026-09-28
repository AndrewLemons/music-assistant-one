import MusicAssistantCore
import SwiftUI

struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var songs: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    ArtworkView(item: item).frame(maxWidth: 240)
                        .contextMenu { MediaActions(item: item) }
                    VStack(spacing: 5) {
                        Text(item.name).font(.title.bold()).multilineTextAlignment(.center)
                        Text(item.subtitle).font(.title3).foregroundStyle(.secondary)
                    }
                    Button { Task { await model.play(item) } } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: 320).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.connection != .connected || model.commandInFlight)
                    .accessibilityLabel("Play \(item.name)")
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                if loading {
                    ProgressView("Loading songs…")
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load() } }
                } else if !loading, songs.isEmpty {
                    ContentUnavailableView(
                        "No Songs",
                        systemImage: "music.note",
                        description: Text("This \(item.kind) doesn’t contain any songs yet.")
                    )
                }
                // A playlist can intentionally contain the same song more than once.
                ForEach(Array(songs.enumerated()), id: \.offset) { _, song in MediaRow(item: song) }
            } header: { Text("Songs") } footer: {
                if !songs.isEmpty {
                    Text("\(songs.count) songs · \(Int(songs.reduce(0) { $0 + $1.duration } / 60)) minutes")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(item.kind == "playlist" ? "Playlist" : "Album")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu { MediaActions(item: item) } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More options for \(item.name)")
                }
            }
            .task(id: item.uri) { await load() }
            .refreshable { await load() }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { songs = try await model.collectionTracks(item) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

struct PlaylistPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    @State private var playlists: [MediaItem] = []
    @State private var loading = true
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.name).font(.headline)
                    Text("Choose a playlist for \(item.isCollection ? "these songs" : "this song").")
                        .foregroundStyle(.secondary)
                }
                if loading {
                    ProgressView("Loading playlists…")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if playlists.isEmpty {
                        Button("Try Again") { Task { await load() } }
                    }
                }
                if !loading, playlists.isEmpty, error == nil {
                    ContentUnavailableView(
                        "No Editable Playlists",
                        systemImage: "music.note.list",
                        description: Text("Create an editable playlist in Music Assistant to add songs here.")
                    )
                }
                ForEach(playlists) { playlist in
                    Button {
                        adding = true; error = nil
                        Task {
                            do { try await model.addToPlaylist(item, playlist: playlist); dismiss() }
                            catch { self.error = error.localizedDescription }
                            adding = false
                        }
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }.disabled(adding)
                }
                if adding {
                    ProgressView("Adding songs…")
                }
            }
            .navigationTitle("Add to Playlist")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(adding) } }
            .task { await load() }
        }
        .interactiveDismissDisabled(adding)
        #if os(macOS)
            .frame(width: 440, height: 500)
        #endif
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { playlists = try await model.editablePlaylists() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

extension EnvironmentValues {
    @Entry var presentPlaylist: (MediaItem) -> Void = { _ in }
}

/// Each presentation surface owns its picker, including sheets such as Playing Next.
struct PlaylistPresentation: ViewModifier {
    @State private var item: MediaItem?
    func body(content: Content) -> some View {
        content
            .environment(\.presentPlaylist) { item = $0 }
            .sheet(item: $item) { PlaylistPicker(item: $0) }
    }
}

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
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Play")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity, alignment: .center)
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
    @State private var page = MediaPager()
    @State private var filter = ""
    @State private var waitingForQuery = false
    @State private var loadGeneration = UUID()
    @State private var adding = false
    @State private var error: String?

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var request: MediaPageRequest {
        .library(collection: "playlists", search: query, order: "sort_name")
    }

    private var playlists: [MediaItem] {
        page.items.filter { model.isDemo || $0.isEditablePlaylist }
    }

    private var canLoad: Bool {
        model.connection == .connected && !model.isDemo && !waitingForQuery && !adding
    }

    private struct LoadIdentity: Equatable {
        let request: MediaPageRequest
        let server: URL?
        let connection: AppModel.Connection
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.name).font(.headline)
                    Text("Choose a playlist for \(item.isCollection ? "these songs" : "this song").")
                        .foregroundStyle(.secondary)
                }
                if model.connection != .connected {
                    ContentUnavailableView(
                        "Connect to Your Server",
                        systemImage: "wifi.exclamationmark",
                        description: Text("A connection is needed to browse and edit playlists.")
                    )
                } else {
                    if waitingForQuery || page.isLoading, playlists.isEmpty {
                        ProgressView("Loading playlists…")
                    }
                    if !waitingForQuery, !page.isLoading, !page.hasMore, playlists.isEmpty, page.error == nil {
                        ContentUnavailableView(
                            query.isEmpty ? "No Editable Playlists" : "No Playlists Found",
                            systemImage: "music.note.list",
                            description: Text(query.isEmpty
                                ? "Create an editable playlist in Music Assistant to add songs here."
                                : "Try another search. Only editable playlists are shown.")
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
                            HStack(spacing: 12) {
                                ArtworkView(item: playlist, cornerRadius: 7).frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name).foregroundStyle(.primary).lineLimit(2)
                                    Text(playlist.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "plus").foregroundStyle(.tint).accessibilityHidden(true)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(adding || waitingForQuery)
                        .accessibilityHint("Adds the selected music to this playlist")
                        .onAppear {
                            let visible = playlists
                            if visible.count >= 5, playlist.id == visible[visible.count - 5].id, page.error == nil {
                                Task { await loadNext() }
                            }
                        }
                    }
                    if !model.isDemo, page.hasMore || page.error != nil || !playlists.isEmpty {
                        PaginationFooter(page: page, enabled: canLoad) { await loadNext() }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if adding {
                    ProgressView("Adding songs…")
                }
            }
            .navigationTitle("Add to Playlist")
            #if os(iOS)
                .searchable(
                    text: $filter,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Find a playlist"
                )
            #else
                .searchable(text: $filter, prompt: "Find a playlist")
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(adding) }
                }
                .task(id: LoadIdentity(request: request, server: model.server?.baseURL, connection: model.connection)) {
                    await reload()
                }
                .onDisappear { page.suspend() }
        }
        .interactiveDismissDisabled(adding)
        #if os(macOS)
            .frame(width: 440, height: 500)
        #endif
    }

    private func reload() async {
        let attempt = UUID()
        loadGeneration = attempt
        waitingForQuery = true
        defer {
            if loadGeneration == attempt {
                waitingForQuery = false
            }
        }
        error = nil
        page.reset(request)
        if model.isDemo {
            page.reset(cached: model.playlists.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            })
            return
        }
        guard model.connection == .connected else { return }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard loadGeneration == attempt else { return }
        waitingForQuery = false
        await loadNext()
    }

    private func loadNext() async {
        guard canLoad, page.request == request else { return }
        await model.loadEditablePlaylistPage(page)
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

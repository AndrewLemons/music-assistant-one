import MusicAssistantCore
import SwiftUI

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
                    HStack(spacing: 12) {
                        ArtworkView(item: item, cornerRadius: 6).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline)
                            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                if model.connection != .connected {
                    ContentUnavailableView(
                        "Offline",
                        systemImage: "wifi.slash",
                        description: Text("Connect to your server to edit playlists.")
                    )
                } else {
                    if waitingForQuery || page.isLoading, playlists.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if !waitingForQuery, !page.isLoading, !page.hasMore, playlists.isEmpty, page.error == nil {
                        if query.isEmpty {
                            ContentUnavailableView(
                                "No Playlists",
                                systemImage: "music.note.list",
                                description: Text("Create a playlist in Music Assistant.")
                            )
                        } else {
                            ContentUnavailableView.search(text: query)
                        }
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
                                    Text(playlist.name).foregroundStyle(.primary).lineLimit(1)
                                    Text(playlist.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "plus.circle").font(.title3).foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(adding || waitingForQuery)
                        .accessibilityHint("Adds to this playlist")
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
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if adding {
                    ProgressView("Adding…").frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add to Playlist")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
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

import MusicAssistantCore
import SwiftUI

struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var songs: [MediaItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var headerTitleVisible = true

    private var isAlbum: Bool {
        item.kind == "album"
    }

    private var details: String {
        let kind = isAlbum ? "Album" : "Playlist"
        guard let year = item.raw["year"].double, year > 0 else { return kind }
        return "\(kind) · \(Int(year))"
    }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Section {
                if loading, songs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                } else if let error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                } else if songs.isEmpty {
                    Text("No Songs").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
                // A playlist can intentionally contain the same song more than once.
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    if isAlbum {
                        MediaRow(
                            item: song,
                            trackNumber: song.raw["track_number"].double.map(Int.init) ?? index + 1,
                            showsSubtitle: song.subtitle != item.subtitle
                        )
                    } else {
                        MediaRow(item: song)
                    }
                }
            } footer: {
                if !songs.isEmpty {
                    Text(collectionSummary(count: songs.count, seconds: songs.reduce(0) { $0 + $1.duration }))
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(item.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The header shows the title; the bar takes over once it scrolls away.
                ToolbarItem(placement: .principal) {
                    Text(item.name).font(.headline).lineLimit(1).opacity(headerTitleVisible ? 0 : 1)
                        .accessibilityHidden(headerTitleVisible)
                }
            }
        #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    DownloadStatusButton(item: item, songs: songs)
                    Menu { MediaActions(item: item) } label: { Label("More", systemImage: "ellipsis") }
                        .accessibilityLabel("More options for \(item.name)")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: headerTitleVisible)
            .task(id: item.uri) { await load() }
            .refreshable { await load() }
    }

    private var header: some View {
        VStack(spacing: 16) {
            ArtworkView(item: item, cornerRadius: 10)
                .frame(maxWidth: 260)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .contextMenu { MediaActions(item: item) }
            VStack(spacing: 4) {
                Text(item.name).font(.title2.bold())
                    .onScrollVisibilityChange(threshold: 0.2) { headerTitleVisible = $0 }
                Text(item.subtitle).font(.title3).foregroundStyle(.tint)
                Text(details).font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            PlayShuffleButtons {
                await model.play(item)
            } shuffle: {
                await model.play(item, shuffled: true)
            }
            .disabled(!model.canPlay(item))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { songs = try await model.collectionTracks(item) }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

/// Toolbar control reflecting a collection's download state.
private struct DownloadStatusButton: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    let songs: [MediaItem]

    private var jobs: [AudioDownload] {
        songs.compactMap { model.downloads.job(for: $0) }
    }

    private var fraction: Double {
        guard !songs.isEmpty else { return 0 }
        let done = songs.reduce(0.0) { total, song in
            if model.downloads.isDownloaded(song) {
                return total + 1
            }
            return total + (model.downloads.job(for: song).flatMap { model.downloads.progress[$0.id] } ?? 0)
        }
        return done / Double(songs.count)
    }

    var body: some View {
        if model.isDownloaded(item) {
            Menu {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    Task { await model.removeDownload(item) }
                }
            } label: {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
            }
        } else if !jobs.isEmpty {
            Button {
                jobs.forEach(model.downloads.cancel)
            } label: {
                DownloadProgressRing(fraction: fraction)
            }
            .accessibilityLabel("Cancel Download")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            .help("Cancel Download")
        } else {
            Button("Download", systemImage: "arrow.down.circle") { Task { await model.download(item) } }
                .disabled(model.connection != .connected || model.isDemo)
                .help("Download")
        }
    }
}

/// A determinate ring with a stop glyph, matching system download controls.
struct DownloadProgressRing: View {
    var fraction: Double
    var paused = false
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            Image(systemName: paused ? "arrow.down" : "stop.fill")
                .font(.system(size: paused ? 10 : 7, weight: .bold))
                .foregroundStyle(.tint)
        }
        .frame(width: 22, height: 22)
    }
}

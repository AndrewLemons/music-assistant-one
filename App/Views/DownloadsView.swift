import MusicAssistantCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var confirmingRemoval = false

    private var songs: [StoredAudio] {
        model.downloads.downloaded
            .filter {
                filter.isEmpty || ($0.media.name + " " + $0.media.subtitle).localizedCaseInsensitiveContains(filter)
            }
    }

    private var collections: [SavedCollection] {
        model.downloads.collections.filter { collection in
            collection.tracks.contains { model.downloads.isDownloaded(MediaItem($0)) } &&
                (filter.isEmpty || MediaItem(collection.metadata).name.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Music that goes with you", systemImage: "arrow.down.circle.fill")
                        .font(.title2.bold())
                    Text(model.downloads.downloaded.isEmpty
                        ? "Save your favorites for flights, road trips, and everywhere in between."
                        :
                        "\(model.downloads.downloaded.count) songs · \(ByteCountFormatter.string(fromByteCount: model.downloads.downloadBytes, countStyle: .file)) · Available offline")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !songs.isEmpty {
                        HStack(spacing: 12) {
                            Button { Task { await model.playDownloads(songs.map(\.media)) } } label: { Label(
                                "Play",
                                systemImage: "play.fill"
                            ).frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel("Play downloaded songs")
                            Button { Task { await model.playDownloads(songs.map(\.media), shuffled: true) } } label: {
                                Label(
                                    "Shuffle",
                                    systemImage: "shuffle"
                                ).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Shuffle downloaded songs")
                        }.controlSize(.large).disabled(model.isDemo)
                    }
                }.padding(.vertical, 12)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)

            if !model.downloads.jobs.isEmpty {
                Section("Downloading") {
                    ForEach(model.downloads.jobs) { job in downloadRow(job) }
                }
            }
            if !collections.isEmpty {
                Section("Albums & Playlists") {
                    ForEach(collections, id: \.metadata["uri"].string) { collection in
                        MediaRow(item: MediaItem(collection.metadata))
                    }
                }
            }
            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(songs) { record in MediaRow(item: record.media) }
                }
            } else if model.downloads.jobs.isEmpty {
                ContentUnavailableView {
                    Label(
                        filter.isEmpty ? "Your Music, Anywhere" : "No Downloads Found",
                        systemImage: filter.isEmpty ? "music.note" : "magnifyingglass"
                    )
                } description: {
                    Text(filter
                        .isEmpty ?
                        "Choose Download from a song, album, or playlist’s menu. Saved songs stay here until you remove them." :
                        "Try another song, artist, or album.")
                }
                .listRowBackground(Color.clear)
            }
            if let error = model.downloads.error {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
            if !model.independentAudioAvailable, model.audioSupportChecked, !model.isDemo {
                Section {
                    Label("Downloads need server support", systemImage: "server.rack")
                    Text(
                        "Online listening and speaker control are ready. Add the optional audio companion to your server to enable downloads and independent playback."
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                    Link("Set Up Downloads", destination: AppLinks.audioCompanion)
                    Button("Check Again") { model.checkAudioSupport(force: true) }
                        .disabled(model.connection != .connected)
                }
            }
        }
        .navigationTitle("Downloaded")
        #if os(iOS)
            .searchable(
                text: $filter,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find downloaded music"
            )
        #else
            .searchable(text: $filter, prompt: "Find downloaded music")
        #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle(
                            "Download over Cellular",
                            isOn: Binding(
                                get: { model.downloads.allowCellular },
                                set: { model.downloads.allowCellular = $0 }
                            )
                        )
                        Button("Remove All Downloads", systemImage: "trash", role: .destructive) {
                            confirmingRemoval = true
                        }
                        .disabled(model.downloads.downloaded.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Download settings")
                }
            }
            .confirmationDialog(
                "Remove all downloaded music?",
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Downloads", role: .destructive) {
                    Task { for record in model.downloads.downloaded {
                        await model.downloads.remove(record.media)
                    } }
                }
            } message: { Text("This frees space on this device. Your server’s music library stays available.") }
            .accessibilityIdentifier("downloadsView")
    }

    private func downloadRow(_ job: AudioDownload) -> some View {
        HStack(spacing: 12) {
            ArtworkView(item: job.media, cornerRadius: 6).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.media.name).lineLimit(2)
                if job.state == .downloading {
                    if let fraction = model.downloads.progress[job.id] {
                        ProgressView(value: fraction).accessibilityLabel("Downloading \(job.media.name)")
                    } else {
                        Text(model.downloads
                            .allowCellular ? "Preparing download…" : "Preparing · Waiting for Wi-Fi if needed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(job.failure ?? (job.state == .paused ? "Paused" : "Waiting to download"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if job.state == .downloading || job.state == .queued {
                    Button("Pause Download", systemImage: "pause") { model.downloads.pause(job) }
                } else {
                    Button(job.state == .failed ? "Try Again" : "Resume Download", systemImage: "arrow.down") {
                        model.downloads.retry(job)
                    }
                }
                Button("Cancel Download", systemImage: "xmark", role: .destructive) { model.downloads.cancel(job) }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("Download options for \(job.media.name)")
        }.padding(.vertical, 4)
    }
}

struct DownloadActions: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        if item.kind == "track" || item.isCollection {
            Section {
                if model.isDownloaded(item) {
                    Button("Remove Download", systemImage: "trash", role: .destructive) {
                        Task { await model.removeDownload(item) }
                    }
                } else if let job = model.downloads.job(for: item) {
                    if job.state == .failed || job.state == .paused {
                        Button("Resume Download", systemImage: "arrow.down.circle") { model.downloads.retry(job) }
                    }
                    Button("Cancel Download", systemImage: "xmark.circle") { model.downloads.cancel(job) }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") { Task { await model.download(item) } }
                        .disabled(model.connection != .connected && !model.downloads.isAvailable(item))
                }
            }
        }
    }
}

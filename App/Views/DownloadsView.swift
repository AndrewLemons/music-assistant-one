import MusicAssistantCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var confirmingRemoval = false

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var songs: [StoredAudio] {
        model.downloads.downloaded.filter {
            query.isEmpty || ($0.media.name + " " + $0.media.subtitle).localizedCaseInsensitiveContains(query)
        }
    }

    private var collections: [SavedCollection] {
        model.downloads.collections.filter { collection in
            collection.tracks.contains { model.downloads.isDownloaded(MediaItem($0)) } &&
                (query.isEmpty || MediaItem(collection.metadata).name.localizedCaseInsensitiveContains(query))
        }
    }

    /// The server can't prepare new downloads; existing ones still play.
    private var needsCompanion: Bool {
        !model.independentAudioAvailable && model.audioSupportChecked && !model.isDemo
    }

    private var isEmpty: Bool {
        model.downloads.downloaded.isEmpty && model.downloads.jobs.isEmpty
    }

    private var summary: String {
        guard !model.downloads.downloaded.isEmpty else { return "" }
        return "\(songCount(model.downloads.downloaded.count)) · \(model.downloads.downloadBytes.fileSize)"
    }

    var body: some View {
        List {
            if !songs.isEmpty {
                PlayShuffleButtons {
                    await model.playDownloads(songs.map(\.media))
                } shuffle: {
                    await model.playDownloads(songs.map(\.media), shuffled: true)
                }
                .disabled(model.isDemo)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            }
            if let error = model.downloads.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            if needsCompanion, !isEmpty {
                Section { companionNotice }
            }
            if !model.downloads.jobs.isEmpty, query.isEmpty {
                Section("Downloading") {
                    ForEach(model.downloads.jobs) { DownloadJobRow(job: $0) }
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
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, record in
                        MediaRow(item: record.media) { await model.playDownloads(songs.map(\.media), start: index) }
                            .swipeActions(edge: .trailing) {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    Task { await model.removeDownload(record.media) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle("Downloaded")
        .navigationSubtitle(summary)
        .searchable(text: $filter, isEnabled: !model.downloads.downloaded.isEmpty, prompt: "Find in Downloaded")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    #if os(iOS)
                        Toggle(
                            "Download over Cellular",
                            systemImage: "antenna.radiowaves.left.and.right",
                            isOn: Binding(
                                get: { model.downloads.allowCellular },
                                set: { model.downloads.allowCellular = $0 }
                            )
                        )
                    #endif
                    Section {
                        Button("Remove All Downloads", systemImage: "trash", role: .destructive) {
                            confirmingRemoval = true
                        }
                        .disabled(model.downloads.downloaded.isEmpty)
                    }
                } label: {
                    Label("Download Options", systemImage: "ellipsis")
                }
                .help("Download Options")
            }
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove All Downloads", role: .destructive) {
                Task {
                    for record in model.downloads.downloaded {
                        await model.downloads.remove(record.media)
                    }
                }
            }
        } message: {
            Text("Frees \(model.downloads.downloadBytes.fileSize). Your server’s library isn’t affected.")
        }
        .accessibilityIdentifier("downloadsView")
    }

    @ViewBuilder private var emptyState: some View {
        if isEmpty {
            if needsCompanion {
                ContentUnavailableView {
                    Label("Downloads Unavailable", systemImage: "arrow.down.circle.dotted")
                } description: {
                    Text("Install the audio companion on your Music Assistant server.")
                } actions: {
                    companionActions
                }
            } else {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download songs, albums, and playlists from their menus.")
                )
            }
        } else if !query.isEmpty, songs.isEmpty, collections.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private var companionNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New downloads require the audio companion on your server.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) { companionActions }
                .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var companionActions: some View {
        Link("Setup Guide", destination: AppLinks.audioCompanion)
        Button("Check Again") { model.checkAudioSupport(force: true) }
            .disabled(model.connection != .connected)
    }
}

/// An in-progress download. The trailing control pauses, resumes, or retries.
private struct DownloadJobRow: View {
    @Environment(AppModel.self) private var model
    let job: AudioDownload

    private var isActive: Bool {
        job.state == .downloading || job.state == .queued
    }

    private var status: String {
        switch job.state {
        case .failed: job.failure ?? "Download Failed"
        case .paused: "Paused"
        case .queued: model.downloads.allowsExpensiveNetworks ? "Waiting" : "Waiting for Wi-Fi"
        case .downloading:
            model.downloads.progress[job.id].map { $0.formatted(.percent.precision(.fractionLength(0))) }
                ?? "Starting…"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: job.media, cornerRadius: 6).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.media.name).lineLimit(1)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(job.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 2)
        .contextMenu { actions }
        .swipeActions(edge: .trailing) {
            Button("Cancel", systemImage: "xmark", role: .destructive) { model.downloads.cancel(job) }
        }
    }

    private var control: some View {
        Group {
            if job.state == .failed {
                Button("Try Again", systemImage: "arrow.clockwise") { model.downloads.retry(job) }
                    .labelStyle(.iconOnly)
            } else {
                Button {
                    isActive ? model.downloads.pause(job) : model.downloads.retry(job)
                } label: {
                    DownloadProgressRing(fraction: model.downloads.progress[job.id] ?? 0, paused: !isActive)
                }
                .accessibilityLabel(isActive ? "Pause Download" : "Resume Download")
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 44, height: 44)
        .help(job.state == .failed ? "Try Again" : isActive ? "Pause Download" : "Resume Download")
    }

    @ViewBuilder private var actions: some View {
        if isActive {
            Button("Pause Download", systemImage: "pause") { model.downloads.pause(job) }
        } else {
            Button(job.state == .failed ? "Try Again" : "Resume Download", systemImage: "arrow.down") {
                model.downloads.retry(job)
            }
        }
        Button("Cancel Download", systemImage: "xmark", role: .destructive) { model.downloads.cancel(job) }
    }
}

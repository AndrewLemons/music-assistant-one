import MusicAssistantCore
import SwiftUI

/// Square artwork with a proportional symbol placeholder.
struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem?
    var cornerRadius: CGFloat = 8
    var body: some View {
        MusicArtworkImage(url: item.flatMap { model.artworkURL(for: $0) }) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            GeometryReader { geometry in
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: item?.kind == "playlist" ? "music.note.list" : "music.note")
                            .font(.system(size: max(12, geometry.size.width * 0.3), weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// Loads downloaded artwork from disk and remote artwork through AsyncImage.
struct MusicArtworkImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var localImage: Image?
    var body: some View {
        Group {
            if url?.isFileURL == true {
                if let localImage {
                    content(localImage)
                } else {
                    placeholder()
                }
            } else {
                AsyncImage(url: url, content: content, placeholder: placeholder)
            }
        }
        .task(id: url) {
            localImage = nil
            guard let url, url.isFileURL,
                  let data = try? await Task.detached(operation: { try Data(contentsOf: url) }).value,
                  !Task.isCancelled else { return }
            #if os(macOS)
                if let image = NSImage(data: data) {
                    localImage = Image(nsImage: image)
                }
            #else
                if let image = UIImage(data: data) {
                    localImage = Image(uiImage: image)
                }
            #endif
        }
    }
}

/// The trailing "•••" menu shared by rows, cards, and players.
struct MoreMenu<Content: View>: View {
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content
    init(_ accessibilityLabel: String, @ViewBuilder content: @escaping () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

/// Grid card for albums and playlists. Mac reveals play and menu controls on hover.
struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var hovering = false

    var body: some View {
        NavigationLink { CollectionDetailView(item: item) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Cards can sit inside list rows, which would otherwise add disclosure chevrons.
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityLabel("\(item.name), \(item.subtitle)")
        .accessibilityAction(named: "Play") { Task { await model.play(item) } }
        // A square overlay at the top of the card covers exactly the artwork.
        .overlay(alignment: .top) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottom) { hoverControls }
        }
        .contextMenu { MediaActions(item: item) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var hoverControls: some View {
        #if os(macOS)
            if hovering {
                HStack {
                    Button { Task { await model.play(item) } } label: {
                        Image(systemName: "play.fill").frame(width: 30, height: 30)
                    }
                    .help("Play")
                    .accessibilityLabel("Play \(item.name)")
                    .disabled(!model.canPlay(item))
                    Spacer()
                    Menu { MediaActions(item: item) } label: {
                        Image(systemName: "ellipsis").frame(width: 30, height: 30)
                    }
                    .menuIndicator(.hidden)
                    .help("More")
                    .accessibilityLabel("More options for \(item.name)")
                }
                .buttonStyle(.glass)
                .menuStyle(.button)
                .buttonBorderShape(.circle)
                .padding(8)
                .transition(.opacity)
            }
        #endif
    }
}

/// A song or collection row. Collections navigate; songs play when chosen.
struct MediaRow: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    /// Album track listings show a number instead of artwork.
    var trackNumber: Int?
    var showsSubtitle = true

    var body: some View {
        HStack(spacing: 4) {
            if item.isCollection {
                NavigationLink { CollectionDetailView(item: item) } label: { label }
                    .buttonStyle(.plain)
                    .navigationLinkIndicatorVisibility(.hidden)
                    .accessibilityLabel("\(item.name), \(item.subtitle)")
                    .accessibilityIdentifier("media-\(item.kind)-\(item.name)")
            } else {
                Button { Task { await model.play(item) } } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(item.name), \(item.subtitle)")
                    .accessibilityIdentifier("media-\(item.kind)-\(item.name)")
                    .disabled(!model.canPlay(item))
            }
            MoreMenu("More options for \(item.name)") { MediaActions(item: item) }
        }
        .contextMenu { MediaActions(item: item) }
        #if os(iOS)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if model.canPlay(item) {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        Task { await model.play(item, option: "next") }
                    }
                    .tint(.orange)
                    Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                        Task { await model.play(item, option: "add") }
                    }
                    .tint(.indigo)
                }
            }
        #endif
    }

    private var label: some View {
        HStack(spacing: 12) {
            if let trackNumber {
                Text(trackNumber, format: .number)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            } else {
                ArtworkView(item: item, cornerRadius: 6).frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).foregroundStyle(.primary)
                if showsSubtitle {
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            MediaBadges(item: item)
        }
        .padding(.vertical, trackNumber == nil ? 2 : 8)
        .contentShape(.rect)
    }
}

/// Favorite, download, and duration indicators. Each has text for VoiceOver.
struct MediaBadges: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var body: some View {
        HStack(spacing: 8) {
            if model.resolvedMedia(item).isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.tint).accessibilityLabel("Favorite")
            }
            if model.isDownloaded(item) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            }
            if item.duration > 0, !item.isCollection {
                Text(formatTime(item.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

/// The standard menu for any song, album, or playlist.
struct MediaActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentPlaylist) private var presentPlaylist
    let item: MediaItem
    var isCurrent = false
    var body: some View {
        if !isCurrent {
            Section {
                Button("Play", systemImage: "play.fill") { Task { await model.play(item) } }
                if item.isCollection {
                    Button("Shuffle", systemImage: "shuffle") { Task { await model.play(item, shuffled: true) } }
                }
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    Task { await model.play(item, option: "next") }
                }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task { await model.play(item, option: "add") }
                }
            }
            .disabled(!model.canPlay(item))
        }
        DownloadActions(item: item)
        Section {
            let favorite = model.resolvedMedia(item).isFavorite
            Button(
                favorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: favorite ? "star.slash" : "star"
            ) {
                Task { await model.toggleFavorite(item) }
            }
            .disabled(model.libraryActionInFlight)
            if item.kind == "track" || item.isCollection {
                Button("Add to Playlist…", systemImage: "music.note.list") { presentPlaylist(item) }
            }
        }
        .disabled(model.connection != .connected)
    }
}

/// Download, resume, cancel, or remove, depending on the item's current state.
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

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let value = Int(max(0, seconds))
    return "\(value / 60):\(String(format: "%02d", value % 60))"
}

/// "12 songs", with grammatical agreement.
func songCount(_ count: Int) -> String {
    String(AttributedString(localized: "^[\(count) song](inflect: true)").characters)
}

/// "12 songs, 48 minutes".
func collectionSummary(count: Int, seconds: Double) -> String {
    let songs = songCount(count)
    guard seconds >= 60 else { return songs }
    let duration = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    return "\(songs), \(duration)"
}

extension View {
    /// Adds a search field only when there is content to search.
    @ViewBuilder func searchable(text: Binding<String>, isEnabled: Bool, prompt: LocalizedStringKey) -> some View {
        if isEnabled {
            searchable(text: text, prompt: Text(prompt))
        } else {
            self
        }
    }
}

extension Int64 {
    var fileSize: String {
        formatted(.byteCount(style: .file))
    }
}

/// The paired Play and Shuffle buttons used at the top of collection pages.
struct PlayShuffleButtons: View {
    let play: () async -> Void
    let shuffle: () async -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await play() } } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("playCollection")
            Button { Task { await shuffle() } } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(TonalButtonStyle())
        .frame(maxWidth: 360)
    }
}

/// A neutral fill with a tinted label, for primary actions placed on content.
struct TonalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect(cornerRadius: 12))
    }
}

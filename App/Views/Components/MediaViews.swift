import MusicAssistantCore
import SwiftUI

/// Square artwork with a proportional symbol placeholder. Artists are circular.
/// Requests a server thumbnail matching the displayed size.
struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let item: MediaItem?
    var cornerRadius: CGFloat = 8
    @State private var width: CGFloat = 0

    private var isArtist: Bool {
        item?.kind == "artist"
    }

    private var symbol: String {
        switch item?.kind {
        case "playlist": "music.note.list"
        case "artist": "music.mic"
        case "radio": "dot.radiowaves.left.and.right"
        default: "music.note"
        }
    }

    var body: some View {
        let pixels = MediaItem.thumbnailSize(Int(width * displayScale))
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ArtworkImage(
                    url: width > 0 ? item.flatMap { model.artworkURL(for: $0, pixels: pixels) } : nil,
                    pixels: pixels
                ) {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: max(12, width * 0.3), weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .clipShape(isArtist ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: cornerRadius)))
            .overlay {
                if isArtist {
                    Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Shows cached artwork synchronously, so revisiting a page doesn't flash placeholders.
struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    let pixels: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        let image = url.flatMap { url in
            loaded?.url == url ? loaded?.image : ArtworkLoader.shared.cached(url, pixels: pixels)
        }
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, ArtworkLoader.shared.cached(url, pixels: pixels) == nil,
                  let image = await ArtworkLoader.shared.image(url, pixels: pixels), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { loaded = (url, image) }
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

/// Grid and shelf card. Albums, playlists, and artists open their page; songs and stations play.
/// Long press for Play, Shuffle, and queue actions. Mac reveals Play and More on hover.
struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    @State private var hovering = false

    private var isArtist: Bool {
        item.kind == "artist"
    }

    var body: some View {
        // A plain button pushes exactly this card's page, even beside other cards in one list
        // row, where navigation links would all activate together.
        Button {
            if let route = Route.page(for: item) {
                model.open(route)
            } else {
                Task { await model.play(item) }
            }
        } label: { label }
            .buttonStyle(.plain)
            .disabled(Route.page(for: item) == nil && !model.canPlay(item))
            .accessibilityAddTraits(Route.page(for: item) == nil ? [] : .isLink)
            .accessibilityLabel(isArtist ? item.name : "\(item.name), \(item.subtitle)")
            .accessibilityIdentifier("card-\(item.kind)-\(item.name)")
            .accessibilityAction(named: "Play") { Task { await model.play(item) } }
            // A square overlay at the top of the card covers exactly the artwork.
            .overlay(alignment: .top) {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottom) { hoverControls }
            }
            .contextMenu { MediaActions(item: item) } preview: { MediaPreview(item: item) }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var label: some View {
        VStack(alignment: isArtist ? .center : .leading, spacing: 8) {
            ArtworkView(item: item)
            VStack(alignment: isArtist ? .center : .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if !isArtist {
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: isArtist ? .center : .leading)
        .contentShape(.rect)
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

/// The long-press preview: large artwork and title, as in the system Music app.
private struct MediaPreview: View {
    let item: MediaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(item: item, cornerRadius: 10).frame(width: 260, height: 260)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                if item.kind != "artist" {
                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(14)
        .frame(width: 288)
    }
}

/// A song or collection row. Collections and artists navigate; songs play when chosen.
/// `play` plays the song within its list, such as an album from that song onward.
struct MediaRow: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    /// Album track listings show a number instead of artwork.
    var trackNumber: Int?
    var showsSubtitle = true
    var play: (() async -> Void)?

    private var isCurrent: Bool {
        !item.isCollection && model.current?.uri == item.uri
    }

    var body: some View {
        HStack(spacing: 4) {
            if let route = Route.page(for: item) {
                NavigationLink(value: route) { label }
                    .buttonStyle(.plain)
                    .navigationLinkIndicatorVisibility(.hidden)
                    .accessibilityLabel(item.kind == "artist" ? item.name : "\(item.name), \(item.subtitle)")
                    .accessibilityIdentifier("media-\(item.kind)-\(item.name)")
            } else {
                Button {
                    Task {
                        if let play {
                            await play()
                        } else {
                            await model.play(item)
                        }
                    }
                } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(item.name), \(item.subtitle)")
                    .accessibilityValue(isCurrent ? "Now Playing" : "")
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
                Group {
                    if isCurrent {
                        NowPlayingIndicator()
                    } else {
                        Text(trackNumber, format: .number)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 24, alignment: .trailing)
            } else {
                ArtworkView(item: item, cornerRadius: 6)
                    .frame(width: 48, height: 48)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                            NowPlayingIndicator().foregroundStyle(.white)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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

/// Animated bars marking the song that is playing, still while paused.
struct NowPlayingIndicator: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Image(systemName: "waveform")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, isActive: model.queue?.isPlaying == true)
            .accessibilityHidden(true)
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
    @Environment(\.currentPage) private var currentPage
    let item: MediaItem
    var isCurrent = false
    var body: some View {
        if !isCurrent {
            Section {
                Button("Play", systemImage: "play.fill") { Task { await model.play(item) } }
                if item.isCollection || item.kind == "artist" {
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
            if let album = item.album, album.uri != currentPage {
                Button("Go to Album", systemImage: "square.stack") { model.open(.collection(album)) }
            }
            if let artist = item.primaryArtist, artist.uri != currentPage {
                Button("Go to Artist", systemImage: "music.mic") { model.open(.artist(artist)) }
            }
        }
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

extension EnvironmentValues {
    /// The item whose page is showing, so menus omit a link back to it.
    @Entry var currentPage: String?
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

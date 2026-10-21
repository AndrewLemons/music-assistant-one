import MusicAssistantCore
import SwiftUI
#if os(iOS)
    import AVKit
#endif

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPlayers = false
    #if os(macOS)
        @SceneStorage("nowPlayingShowsQueue") private var showingQueue = true
    #endif

    private var isPlaying: Bool {
        model.queue?.isPlaying == true
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            GeometryReader { geometry in
                #if os(macOS)
                    ScrollView {
                        playerContent(artworkSize: min(360, max(140, geometry.size.height - 320)))
                            .frame(maxWidth: 440)
                            .padding(32)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                #else
                    ScrollView {
                        playerContent(artworkSize: min(geometry.size.width - 56, geometry.size.height * 0.46))
                            .frame(maxWidth: 480)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                #endif
            }
            .background {
                ArtworkBackground(url: model.current.flatMap { model.artworkURL(for: $0, pixels: 256) })
                    .ignoresSafeArea()
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .navigationTitle("Now Playing")
            #endif
            .toolbar {
                #if os(macOS)
                    ToolbarItem(placement: .navigation) { closeButton.keyboardShortcut(.escape, modifiers: []) }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { showingPlayers = true } label: {
                            Label(model.selectedPlayerName ?? "Choose Player", systemImage: "hifispeaker.2")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Choose Player")
                        if let player = model.selectedPlayer, model.showsVolume(for: player) {
                            PlayerVolume(player: player).frame(width: 150).padding(.horizontal, 8)
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: $showingQueue.animation()) {
                            Label("Queue", systemImage: "list.bullet")
                        }
                        .help(showingQueue ? "Hide Queue" : "Show Queue")
                    }
                #else
                    ToolbarItem(placement: .cancellationAction) { closeButton.tint(.primary) }
                #endif
            }
            .sheet(isPresented: $showingPlayers) {
                NavigationStack { PlayersView(isSheet: true) }.presentationDetents([.medium, .large])
            }
            #if os(iOS)
            .sheet(isPresented: $model.showQueue) { QueueView() }
            #else
            // The system inspector gives the queue a full-height, resizable trailing panel.
            .inspector(isPresented: $showingQueue) {
                QueueContent()
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
            }
            #endif
        }
        .modifier(PlaylistPresentation())
        .accessibilityIdentifier("nowPlayingView")
        #if os(iOS)
            .presentationDragIndicator(.visible)
            .presentationSizing(.page)
        #endif
    }

    private var closeButton: some View {
        Button { model.showNowPlaying = false } label: {
            #if os(macOS)
                Label("Close Now Playing", systemImage: "xmark")
            #else
                Label("Close Now Playing", systemImage: "chevron.down")
            #endif
        }
        .help("Close Now Playing")
    }

    /// On iOS, controls use the primary color over the artwork-tinted background, as in the system player.
    private func playerContent(artworkSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            ArtworkView(item: model.current, cornerRadius: 14)
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(isPlaying ? 0.25 : 0.12), radius: isPlaying ? 24 : 12, y: 10)
                // Like the system player, artwork recedes while paused.
                .scaleEffect(isPlaying || reduceMotion ? 1 : 0.86)
                .animation(.spring(duration: 0.45, bounce: 0.2), value: isPlaying)
                .contextMenu {
                    if let item = model.current {
                        MediaActions(item: item, isCurrent: true)
                    }
                }
            Spacer(minLength: 24)
            VStack(spacing: 20) {
                titleRow
                statusLine
                if let queue = model.queue {
                    PlaybackProgressView(queue: queue)
                } else {
                    Slider(value: .constant(0), in: 0 ... 1).disabled(true).accessibilityLabel("Playback position")
                }
                ViewThatFits(in: .horizontal) {
                    TransportControls()
                    TransportControls(compact: true)
                }
                #if os(iOS)
                    if let player = model.selectedPlayer, model.showsVolume(for: player) {
                        PlayerVolume(player: player)
                    }
                    outputBar
                #endif
            }
        }
        #if os(iOS)
        .tint(.primary)
        #endif
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.current?.name ?? "Not Playing").font(.title3.bold())
                if let current = model.current {
                    let destination = current.album.map(Route.collection) ?? current.primaryArtist.map(Route.artist)
                    Button { destination.map(model.open) } label: {
                        Text(current.subtitle).font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(destination == nil)
                    .accessibilityHint(destination == nil ? "" : "Opens the album")
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let item = model.current {
                let favorite = model.resolvedMedia(item).isFavorite
                Group {
                    Button {
                        Task { await model.toggleFavorite(item) }
                    } label: {
                        CircleGlyph(symbol: favorite ? "star.fill" : "star")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(favorite ? "Remove from Favorites" : "Add to Favorites")
                    .disabled(model.connection != .connected || model.libraryActionInFlight)
                    Menu { MediaActions(item: item, isCurrent: true) } label: { CircleGlyph(symbol: "ellipsis") }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Track options")
                }
                // macOS fills tinted glass buttons with the accent color; bordered stays neutral.
                #if os(macOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.glass)
                #endif
                .buttonBorderShape(.circle)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let error = model.devicePlaybackError, model.isDeviceSelected {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    #if os(iOS)
        /// Output selection on the left; AirPlay and the queue on the right.
        private var outputBar: some View {
            HStack(spacing: 12) {
                Button { showingPlayers = true } label: {
                    Label(model.selectedPlayerName ?? "Choose Player", systemImage: "hifispeaker.2")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Choose player")
                .accessibilityValue(model.selectedPlayerName ?? "None")
                Spacer()
                if model.isDeviceSelected {
                    RoutePicker()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                }
                Button { model.showQueue = true } label: { CircleGlyph(symbol: "list.bullet") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Queue")
            }
        }
    #endif
}

#if os(iOS)
    struct RoutePicker: UIViewRepresentable {
        func makeUIView(context _: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.prioritizesVideoDevices = false
            picker.tintColor = .label
            return picker
        }

        func updateUIView(_: AVRoutePickerView, context _: Context) {}
    }
#endif

/// A fixed-size symbol so neighboring circular buttons match.
private struct CircleGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: 24, height: 24)
    }
}

/// Blurring the artwork preserves its palette without making text compete with detail.
private struct ArtworkBackground: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            ArtworkImage(url: url, pixels: 256) { Color.clear }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .blur(radius: 70).opacity(0.5)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(.regularMaterial.opacity(0.6))
                .background(.background)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

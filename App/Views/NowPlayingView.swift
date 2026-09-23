import MusicAssistantCore
import SwiftUI
#if os(iOS)
    import AVKit
#endif

struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    @State private var showingQueue = false
    @State private var showingVolume = false
    var body: some View {
        HStack(spacing: 12) {
            #if os(macOS)
                ViewThatFits(in: .horizontal) {
                    TransportControls(compact: true)
                    TransportControls(compact: true, includesModes: false)
                }.fixedSize()
                Divider().frame(height: 28)
            #endif
            Button { model.showNowPlaying = true } label: {
                HStack(spacing: 10) {
                    ArtworkView(item: model.current, cornerRadius: 5).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.current?.name ?? "Not Playing")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(model.current?.subtitle ?? "Choose music to get started")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("miniPlayer")
            .accessibilityLabel("Show Now Playing")
            .accessibilityValue(model.current?.name ?? "Not Playing")
            .help("Show Now Playing")
            #if os(iOS)
                PlaybackButton(
                    symbol: model.queue?.isPlaying == true ? "pause.fill" : "play.fill",
                    label: model.queue?.isPlaying == true ? "Pause" : "Play",
                    size: 20,
                    width: 40
                ) {
                    Task { await model.togglePlayback() }
                }.disabled(!model.canControl)
            #else
                PlaybackButton(symbol: "list.bullet", label: "Playing next", selected: showingQueue) {
                    showingQueue.toggle()
                }
                .popover(isPresented: $showingQueue) { QueueView() }
            #endif
            PlaybackButton(symbol: "hifispeaker.2", label: "Choose player") { model.showPlayers = true }
                .accessibilityValue(model.selectedPlayer?.name ?? "No player selected")
            #if os(macOS)
                PlaybackButton(symbol: "speaker.wave.2", label: "Volume") { showingVolume.toggle() }
                    .disabled(model.selectedPlayer?.volume == nil)
                    .popover(isPresented: $showingVolume) {
                        if let player = model.selectedPlayer {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(player.name).font(.headline)
                                PlayerVolume(player: player)
                            }.padding(20).frame(width: 260)
                        }
                    }
            #endif
        }
        .padding(.vertical, 8)
    }
}

/// A consistent symbol weight and hit target for every playback surface.
struct PlaybackButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    var width: CGFloat = 30
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: width, height: max(32, width))
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var compact = false
    var includesModes = true
    private var controlWidth: CGFloat {
        compact ? 28 : 48
    }

    var body: some View {
        HStack(spacing: compact ? 0 : 12) {
            if includesModes {
                PlaybackButton(
                    symbol: "shuffle",
                    label: "Shuffle",
                    size: compact ? 12 : 17,
                    width: controlWidth,
                    selected: model.queue?.shuffle == true
                ) {
                    Task { await model.queueCommand(
                        "shuffle",
                        args: ["shuffle_enabled": .bool(!(model.queue?.shuffle ?? false))]
                    ) }
                }
                .disabled(!model.canControl || model.queue == nil)
                .accessibilityValue(model.queue?.shuffle == true ? "On" : "Off")
            }
            PlaybackButton(
                symbol: "backward.fill",
                label: "Previous track",
                size: compact ? 17 : 26,
                width: controlWidth
            ) {
                Task { await model.playback("previous") }
            }.disabled(!model.canControl)
            PlaybackButton(
                symbol: model.queue?.isPlaying == true ? "pause.fill" : "play.fill",
                label: model.queue?.isPlaying == true ? "Pause" : "Play",
                size: compact ? 22 : 40,
                width: compact ? 36 : 70
            ) {
                Task { await model.togglePlayback() }
            }.disabled(!model.canControl)
            PlaybackButton(symbol: "forward.fill", label: "Next track", size: compact ? 17 : 26, width: controlWidth) {
                Task { await model.playback("next") }
            }.disabled(!model.canControl)
            if includesModes {
                PlaybackButton(
                    symbol: model.queue?.repeatMode == "one" ? "repeat.1" : "repeat",
                    label: "Repeat",
                    size: compact ? 12 : 17,
                    width: controlWidth,
                    selected: model.queue != nil && model.queue?.repeatMode != "off"
                ) {
                    let next = model.queue?.repeatMode == "off" ? "all" : model.queue?.repeatMode == "all" ? "one" : "off"
                    Task { await model.queueCommand("repeat", args: ["repeat_mode": .string(next)]) }
                }
                .disabled(!model.canControl || model.queue == nil)
                .accessibilityValue(model.queue?.repeatMode ?? "off")
            }
        }
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var showingQueue = true
    @State private var showingPlayers = false
    @State private var showingMobileQueue = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                #if os(macOS)
                    HStack(spacing: 0) {
                        ScrollView {
                            playerContent(artworkSize: min(340, max(140, geometry.size.height - 300)))
                                .frame(maxWidth: 430)
                                .padding(24)
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                        if showingQueue {
                            Divider().padding(.vertical, 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Playing Next").font(.title2.bold()).padding(24)
                                QueueContent()
                            }
                            .frame(width: min(360, geometry.size.width * 0.4))
                        }
                    }
                #else
                    ScrollView {
                        playerContent(artworkSize: min(340, max(180, geometry.size.height * 0.38)))
                            .frame(maxWidth: 440).padding(28).frame(maxWidth: .infinity)
                    }
                #endif
            }
            .background {
                ArtworkBackground(url: model.current?.artworkURL(server: model.server))
                    .ignoresSafeArea()
            }
            .navigationTitle("Now Playing")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(macOS)
                        ToolbarItem(placement: .navigation) { closeButton.keyboardShortcut(.escape, modifiers: []) }
                    #else
                        ToolbarItem(placement: .cancellationAction) { closeButton }
                    #endif
                    #if os(macOS)
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button { showingPlayers = true } label: {
                                Label(model.selectedPlayer?.name ?? "Choose Player", systemImage: "hifispeaker.2")
                            }.help("Choose player · \(model.selectedPlayer?.name ?? "No player selected")")
                            if let player = model.selectedPlayer, player.volume != nil {
                                PlayerVolume(player: player).frame(width: 160).padding(.horizontal, 8)
                            }
                            Button { showingQueue.toggle() } label: { Image(systemName: "list.bullet") }
                                .accessibilityLabel("Toggle Playing Next")
                                .accessibilityValue(showingQueue ? "Shown" : "Hidden")
                                .help("Show or hide Playing Next")
                        }
                    #endif
                }
                .sheet(isPresented: $showingMobileQueue) { QueueView() }
                .sheet(isPresented: $showingPlayers) {
                    NavigationStack { PlayersView(isSheet: true) }.presentationDetents([.medium, .large])
                }
        }
        .accessibilityIdentifier("nowPlayingView")
        #if os(iOS)
            .presentationDragIndicator(.visible)
            .presentationSizing(.page)
        #endif
    }

    private var closeButton: some View {
        Button { model.showNowPlaying = false } label: { Image(systemName: closeSymbol) }
            .accessibilityLabel("Close Now Playing")
            .help("Close Now Playing")
    }

    private var closeSymbol: String {
        #if os(macOS)
            "xmark"
        #else
            "chevron.down"
        #endif
    }

    private var playerSpacing: CGFloat {
        #if os(macOS)
            16
        #else
            22
        #endif
    }

    private func playerContent(artworkSize: CGFloat) -> some View {
        VStack(spacing: playerSpacing) {
            ArtworkView(item: model.current, cornerRadius: 12)
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(model.current?.name ?? "Not Playing").font(.title2.bold())
                    Spacer()
                    if let item = model.current {
                        Menu { MediaActions(item: item) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel("Track options")
                    }
                }
                Text(model.current?.subtitle ?? "Choose something from your library or search.")
                    .font(.title3).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
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
                if let player = model.selectedPlayer, player.volume != nil {
                    PlayerVolume(player: player)
                }
                HStack {
                    Button { showingPlayers = true } label: {
                        Label(model.selectedPlayer?.name ?? "Choose Player", systemImage: "hifispeaker.2")
                            .font(.subheadline).lineLimit(1)
                    }
                    Spacer()
                    if model.selectedPlayerID == model.local.clientID, model.local.isConnected {
                        RoutePicker().frame(width: 32, height: 44).accessibilityLabel("Audio output")
                    }
                    PlaybackButton(symbol: "list.bullet", label: "Playing next", width: 44) { showingMobileQueue = true
                    }
                }.buttonStyle(.plain)
            #endif
        }
    }
}

struct PlaybackProgressView: View {
    @Environment(AppModel.self) private var model
    let queue: PlayerQueue
    @State private var scrubbing = false
    @State private var position = 0.0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = scrubbing ? position : queue.elapsed(at: timeline.date)
            VStack(spacing: 4) {
                Slider(value: Binding(get: { elapsed }, set: { position = $0 }), in: 0 ... max(1, queue.duration)) {
                    Text("Playback position")
                } onEditingChanged: { active in
                    if active {
                        position = queue.elapsed()
                    }
                    scrubbing = active
                    if !active {
                        Task { await model.queueCommand("seek", args: ["position": .number(position.rounded())]) }
                    }
                }
                .labelsHidden()
                .disabled(queue.duration <= 0 || !model.canControl)
                .accessibilityValue("\(formatTime(elapsed)) of \(formatTime(queue.duration))")
                HStack {
                    Text(formatTime(elapsed))
                    Spacer()
                    Text(queue.duration > 0 ? "−\(formatTime(max(0, queue.duration - elapsed)))" : "Live")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct QueueContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.queueLoading, model.queueItems.isEmpty {
                ProgressView("Loading your queue…")
            } else if let error = model.queueError {
                ContentUnavailableView {
                    Label("Queue Unavailable", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.loadQueueItems() } }
                }
            } else if model.queueItems.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "music.note.list",
                    description: Text("Use Play Next or Add to Queue on any song, album, or playlist.")
                )
            } else {
                List(model.queueItems) { entry in
                    Button { Task { await model.queueCommand("play_index", args: ["index": .string(entry.id)]) }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(item: entry.media, cornerRadius: 5).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.media.name).foregroundStyle(.primary).lineLimit(1)
                                Text(entry.media.subtitle).foregroundStyle(.secondary).font(.subheadline).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if entry.media.uri == model.current?.uri {
                                Image(systemName: "waveform").foregroundStyle(.tint).accessibilityLabel("Current song")
                            }
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!model.canControl)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.queue?.id) { await model.loadQueueItems() }
        .onChange(of: model.queue) { _, _ in Task { await model.loadQueueItems() } }
    }
}

struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            QueueContent()
                .navigationTitle("Playing Next")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 380, height: 480)
        #endif
    }
}

#if os(iOS)
    struct RoutePicker: UIViewRepresentable {
        func makeUIView(context _: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.prioritizesVideoDevices = false
            return picker
        }

        func updateUIView(_: AVRoutePickerView, context _: Context) {}
    }
#endif

/// Blurring the artwork preserves its palette without making text compete with detail.
private struct ArtworkBackground: View {
    let url: URL?
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 70).opacity(0.45)
                } else {
                    Color.clear
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(.regularMaterial.opacity(0.65))
            .background(.background)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

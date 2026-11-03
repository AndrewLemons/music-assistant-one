import MusicAssistantCore
import SwiftUI

/// iOS: the tab bar accessory. Mac: the floating bar along the bottom of the window.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
        @State private var showingQueue = false
        @State private var showingVolume = false
    #else
        /// Inline beside a minimized tab bar, only play/pause fits, as in the system Music app.
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        /// The song follows the finger while swiping, then the next one slides in.
        @State private var swipeOffset: CGFloat = 0
        @State private var swipes = 0
    #endif

    var body: some View {
        #if os(macOS)
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    TransportControls(compact: true)
                    TransportControls(compact: true, includesModes: false)
                }
                .fixedSize()
                Divider().frame(height: 28)
                nowPlayingButton(artworkSize: 40)
                PlaybackButton(symbol: "list.bullet", label: "Queue", selected: showingQueue) {
                    showingQueue.toggle()
                }
                .popover(isPresented: $showingQueue) { QueueView() }
                PlaybackButton(symbol: "hifispeaker.2", label: "Choose player") { model.showPlayers = true }
                    .accessibilityValue(model.selectedPlayerName ?? "None")
                if let player = model.selectedPlayer, model.showsVolume(for: player) {
                    PlaybackButton(symbol: "speaker.wave.2", label: "Volume", selected: showingVolume) {
                        showingVolume.toggle()
                    }
                    .popover(isPresented: $showingVolume) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(player.name).font(.headline)
                            PlayerVolume(player: player)
                        }
                        .padding(20)
                        .frame(width: 260)
                    }
                }
            }
            .padding(.vertical, 8)
        #else
            HStack(spacing: 0) {
                nowPlayingButton(artworkSize: 32)
                    .offset(x: swipeOffset)
                    .padding(.leading, 8)
                    .clipped()
                    // Swipe the song to change tracks, as in the system Music app. The drag takes
                    // priority once it moves, so the button's tap can't swallow a swipe.
                    .highPriorityGesture(swipeToSkip)
                    .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: swipes)
                    .accessibilityAction(named: "Next Track") {
                        Task {
                            if model.supportsPlayback("next") {
                                await model.playback("next")
                            }
                        }
                    }
                    .accessibilityAction(named: "Previous Track") {
                        Task {
                            if model.supportsPlayback("previous") {
                                await model.playback("previous")
                            }
                        }
                    }
                let remote = !model.isDeviceSelected && model.selectedPlayer != nil
                let compact = placement == .inline
                if !compact {
                    PlaybackButton(
                        symbol: remote ? "hifispeaker.fill" : "hifispeaker",
                        label: "Choose Player",
                        size: 16,
                        selected: remote
                    ) { model.showPlayers = true }
                        .accessibilityValue(model.selectedPlayerName ?? "None")
                        .accessibilityIdentifier("miniPlayerOutput")
                }
                let playing = model.queue?.isPlaying == true
                PlaybackButton(
                    symbol: playing ? "pause.fill" : "play.fill",
                    label: playing ? "Pause" : "Play",
                    size: 18,
                    loading: model.isLoadingAudio
                ) {
                    Task { await model.togglePlayback() }
                }
                .disabled(!model.canControl || !model.supportsPlayback(playing ? "pause" : "play"))
                if !compact {
                    PlaybackButton(symbol: "forward.fill", label: "Next track", size: 16, bounces: true) {
                        Task {
                            if model.supportsPlayback("next") {
                                await model.playback("next")
                            }
                        }
                    }
                    .disabled(!model.canControl || !model.supportsPlayback("next"))
                }
                Spacer().frame(width: 6)
            }
            // The accessory has a fixed height, so cap text size as the tab bar does.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        #endif
    }

    #if os(iOS)
        private var swipeToSkip: some Gesture {
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard model.canControl, abs(value.translation.width) > abs(value.translation.height) else { return }
                    // Resist past the threshold, so the song can't be dragged away entirely.
                    let width = value.translation.width
                    swipeOffset = width
                        .magnitude < 60 ? width : (60 + (width.magnitude - 60) * 0.3) * (width < 0 ? -1 : 1)
                }
                .onEnded { value in
                    let width = value.predictedEndTranslation.width
                    let skips = model.canControl && model
                        .supportsPlayback(width < 0 ? "next" : "previous") && abs(value.translation.width) > 40 &&
                        abs(width) > 80 &&
                        abs(value.translation.width) > abs(value.translation.height) * 1.5
                    guard skips else {
                        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { swipeOffset = 0 }
                        return
                    }
                    let forward = width < 0
                    swipes += 1
                    Task { await model.playback(forward ? "next" : "previous") }
                    guard !reduceMotion else { swipeOffset = 0; return }
                    // The new song enters from the side the old one left toward.
                    var exit = Transaction(animation: .easeIn(duration: 0.12))
                    exit.addAnimationCompletion {
                        swipeOffset = forward ? 80 : -80
                        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { swipeOffset = 0 }
                    }
                    withTransaction(exit) { swipeOffset = forward ? -120 : 120 }
                }
        }
    #endif

    private func nowPlayingButton(artworkSize: CGFloat) -> some View {
        Button { model.showNowPlaying = true } label: {
            HStack(spacing: 10) {
                ArtworkView(item: model.current, cornerRadius: 6)
                    .frame(width: artworkSize, height: artworkSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.current?.name ?? "Not Playing")
                        .font(.subheadline.weight(.medium))
                    if let current = model.current {
                        Text(model.isDeviceSelected ? current
                            .subtitle : "\(current.subtitle) · \(model.selectedPlayerName ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("miniPlayer")
        .accessibilityLabel("Now Playing")
        .accessibilityValue(model.current?.name ?? "Not Playing")
        .help("Show Now Playing")
        .contextMenu {
            if let item = model.current {
                MediaActions(item: item, isCurrent: true)
            }
        }
    }
}

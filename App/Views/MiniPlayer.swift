import MusicAssistantCore
import SwiftUI

/// iOS: the tab bar accessory. Mac: the floating bar along the bottom of the window.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
        @State private var showingQueue = false
        @State private var showingVolume = false
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
            HStack(spacing: 4) {
                nowPlayingButton(artworkSize: 32)
                    .padding(.leading, 8)
                let playing = model.queue?.isPlaying == true
                PlaybackButton(
                    symbol: playing ? "pause.fill" : "play.fill",
                    label: playing ? "Pause" : "Play",
                    size: 18
                ) {
                    Task { await model.togglePlayback() }
                }
                .disabled(!model.canControl)
                PlaybackButton(symbol: "forward.fill", label: "Next track", size: 16) {
                    Task { await model.playback("next") }
                }
                .disabled(!model.canControl)
                .padding(.trailing, 6)
            }
            // The accessory has a fixed height, so cap text size as the tab bar does.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        #endif
    }

    private func nowPlayingButton(artworkSize: CGFloat) -> some View {
        Button { model.showNowPlaying = true } label: {
            HStack(spacing: 10) {
                ArtworkView(item: model.current, cornerRadius: 6).frame(width: artworkSize, height: artworkSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.current?.name ?? "Not Playing")
                        .font(.subheadline.weight(.medium))
                    if let subtitle = model.current?.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
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

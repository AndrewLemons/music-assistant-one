import MusicAssistantCore
import SwiftUI

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
                .contentTransition(.symbolEffect(.replace))
            #if os(iOS)
                .frame(width: max(44, width), height: max(44, width))
            #else
                .frame(width: width, height: max(32, width))
            #endif
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
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
        compact ? 28 : 52
    }

    private var isPlaying: Bool {
        model.queue?.isPlaying == true
    }

    var body: some View {
        HStack(spacing: compact ? 0 : 8) {
            if includesModes {
                PlaybackButton(
                    symbol: "shuffle",
                    label: "Shuffle",
                    size: compact ? 12 : 18,
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
                if !compact {
                    Spacer(minLength: 0)
                }
            }
            PlaybackButton(
                symbol: "backward.fill",
                label: "Previous track",
                size: compact ? 17 : 28,
                width: controlWidth
            ) {
                Task { await model.playback("previous") }
            }
            .disabled(!model.canControl)
            if !compact {
                Spacer(minLength: 0)
            }
            PlaybackButton(
                symbol: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                size: compact ? 22 : 44,
                width: compact ? 36 : 72
            ) {
                Task { await model.togglePlayback() }
            }
            .disabled(!model.canControl)
            if !compact {
                Spacer(minLength: 0)
            }
            PlaybackButton(symbol: "forward.fill", label: "Next track", size: compact ? 17 : 28, width: controlWidth) {
                Task { await model.playback("next") }
            }
            .disabled(!model.canControl)
            if includesModes {
                if !compact {
                    Spacer(minLength: 0)
                }
                PlaybackButton(
                    symbol: model.queue?.repeatMode == "one" ? "repeat.1" : "repeat",
                    label: "Repeat",
                    size: compact ? 12 : 18,
                    width: controlWidth,
                    selected: model.queue != nil && model.queue?.repeatMode != "off"
                ) {
                    let next = model.queue?.repeatMode == "off" ? "all" : model.queue?.repeatMode == "all" ? "one" : "off"
                    Task { await model.queueCommand("repeat", args: ["repeat_mode": .string(next)]) }
                }
                .disabled(!model.canControl || model.queue == nil)
                .accessibilityValue(repeatValue)
            }
        }
    }

    private var repeatValue: String {
        switch model.queue?.repeatMode {
        case "all": "All"
        case "one": "One"
        default: "Off"
        }
    }
}

/// Scrubber with elapsed and remaining time. Seeks when dragging ends.
struct PlaybackProgressView: View {
    @Environment(AppModel.self) private var model
    let queue: PlayerQueue
    @State private var scrubbing = false
    @State private var position = 0.0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = scrubbing ? position : queue.elapsed(at: timeline.date)
            VStack(spacing: 2) {
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
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }
}

struct PlayerVolume: View {
    @Environment(AppModel.self) private var model
    let player: Player
    @State private var draft: Double = 0
    @State private var editing = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            // Keep the control continuous to avoid tick marks; setVolume rounds the command.
            Slider(value: Binding(
                get: { draft },
                set: { value in
                    draft = value
                    model.setVolume(value, player: player)
                }
            ), in: 0 ... 100) { Text("Volume") } onEditingChanged: { editing = $0 }
                .labelsHidden()
                .controlSize(.small)
                .tint(.primary)
                .accessibilityValue("\(Int(draft.rounded())) percent")
                .disabled(model.connection != .connected || model.isDemo || !player.available)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .font(.caption)
        .onAppear { draft = player.volume ?? 0 }
        .onChange(of: player.volume) { _, value in
            if !editing {
                draft = value ?? 0
            }
        }
        .onChange(of: player.id) { _, _ in editing = false; draft = player.volume ?? 0 }
    }
}

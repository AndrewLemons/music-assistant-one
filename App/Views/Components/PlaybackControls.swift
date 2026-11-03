import MusicAssistantCore
import SwiftUI

/// A consistent symbol weight and hit target for every playback surface.
struct PlaybackButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    var width: CGFloat = 30
    var selected = false
    /// Replaces the symbol with a spinner while audio loads, as the system player does.
    var loading = false
    /// Next and Previous nudge their symbol on each tap.
    var bounces = false
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce.down, options: .speed(1.6), value: bounces ? taps : 0)
                .opacity(loading ? 0 : 1)
                .overlay {
                    if loading {
                        ProgressView().controlSize(size > 30 ? .large : .regular)
                    }
                }
            #if os(iOS)
                .frame(width: max(44, width), height: max(44, width))
            #else
                .frame(width: width, height: max(32, width))
            #endif
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background(
                    selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 8)
                )
                .contentShape(.rect)
        }
        .buttonStyle(TransportButtonStyle())
        #if os(iOS)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: taps)
        #endif
            .accessibilityLabel(label)
            .accessibilityValue(loading ? "Loading" : "")
            .help(label)
    }
}

/// Transport buttons respond on touch-down, as in the system player: the symbol shrinks
/// over a soft highlight, then springs back.
private struct TransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(.primary.opacity(configuration.isPressed ? 0.1 : 0))
                    .padding(-4)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.86 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
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
                .disabled(!model.canControl || !model.supportsPlayback("shuffle") || model.queue == nil)
                .accessibilityValue(model.queue?.shuffle == true ? "On" : "Off")
                if !compact {
                    Spacer(minLength: 0)
                }
            }
            PlaybackButton(
                symbol: "backward.fill",
                label: "Previous track",
                size: compact ? 17 : 28,
                width: controlWidth,
                bounces: true
            ) {
                Task { await model.playback("previous") }
            }
            .disabled(!model.canControl || !model.supportsPlayback("previous"))
            if !compact {
                Spacer(minLength: 0)
            }
            PlaybackButton(
                symbol: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                size: compact ? 22 : 44,
                width: compact ? 36 : 72,
                loading: model.isLoadingAudio
            ) {
                Task { await model.togglePlayback() }
            }
            .disabled(!model.canControl || !model.supportsPlayback(isPlaying ? "pause" : "play"))
            if !compact {
                Spacer(minLength: 0)
            }
            PlaybackButton(
                symbol: "forward.fill",
                label: "Next track",
                size: compact ? 17 : 28,
                width: controlWidth,
                bounces: true
            ) {
                Task { await model.playback("next") }
            }
            .disabled(!model.canControl || !model.supportsPlayback("next"))
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
                .disabled(!model.canControl || !model.supportsPlayback("repeat") || model.queue == nil)
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
///
/// TransportControl retains a released seek until confirmation. Display smoothing is scoped
/// to the queue occurrence, so switching songs clears both the draft and the old clock.
struct PlaybackProgressView: View {
    @Environment(AppModel.self) private var model
    let queue: PlayerQueue
    @State private var scrubbing = false
    @State private var position = 0.0
    @State private var clock = PlaybackClock()

    var body: some View {
        // Move smoothly while playing; a paused clock needs no timer.
        TimelineView(.animation(minimumInterval: 0.2, paused: !queue.isPlaying || scrubbing)) { timeline in
            let elapsed = scrubbing ? position : clock.value(queue, at: timeline.date)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { elapsed }, set: { position = $0 }), in: 0 ... max(1, queue.duration)) {
                    Text("Playback position")
                } onEditingChanged: { active in
                    PlaybackDiagnostics.log(
                        "scrubber editing=\(active) scrubbing=\(scrubbing) position=\(position) queue=\(queue.id) item=\(queue.itemID ?? "-")"
                    )
                    guard active || scrubbing else { return }
                    if active {
                        position = elapsed
                    } else {
                        let target = position.rounded()
                        let queueID = queue.id
                        let itemID = queue.itemID
                        Task {
                            await model.queueCommand(
                                "seek",
                                args: ["position": .number(target)],
                                queueID: queueID,
                                expectedItemID: itemID
                            )
                        }
                    }
                    scrubbing = active
                }
                .labelsHidden()
                .disabled(queue.duration <= 0 || !model.canControl || !model.supportsPlayback("seek"))
                .accessibilityValue("\(formatTime(elapsed)) of \(formatTime(queue.duration))")
                HStack {
                    Text(formatTime(elapsed))
                    Spacer()
                    Text(queue.duration > 0 ? "−\(formatTime(max(0, queue.duration - elapsed)))" : "Live")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityHidden(true)
            }
        }
        .onChange(of: queue.id) { _, _ in scrubbing = false; clock = PlaybackClock() }
        .onChange(of: queue.itemID) { _, _ in scrubbing = false; clock = PlaybackClock() }
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
            ), in: 0 ... 100) { Text("Volume") } onEditingChanged: { active in
                editing = active
                if !active {
                    draft = model.displayedVolume(for: player) ?? 0
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .tint(.primary)
            .accessibilityValue("\(Int(draft.rounded())) percent")
            .disabled(model.connection != .connected || model.isDemo || !player.available || !model
                .showsVolume(for: player))
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .font(.caption)
        .onAppear { draft = model.displayedVolume(for: player) ?? 0 }
        .onChange(of: model.displayedVolume(for: player)) { _, value in
            if !editing {
                draft = value ?? 0
            }
        }
        .onChange(of: player.id) { _, _ in editing = false; draft = model.displayedVolume(for: player) ?? 0 }
    }
}

/// A brief message after a command fails and the controls revert.
struct CommandNotice: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { AccessibilityNotification.Announcement(notice).post() }
            }
        }
        .animation(.spring(duration: 0.35), value: model.notice)
    }
}

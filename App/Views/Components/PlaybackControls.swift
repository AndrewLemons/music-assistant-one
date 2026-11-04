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
    /// The displayed queue. A momentary gap (a speaker rebuilding its stream) keeps the last
    /// one, so a drag in progress is never torn down.
    let queue: PlayerQueue?
    @State private var lastQueue: PlayerQueue?
    @State private var drag: Drag?
    /// A released target, shown until playback reports a position near it.
    @State private var released: (itemID: String?, value: Double, at: Date)?
    @State private var clock = PlaybackClock()
    @State private var now = Date.now

    /// The occurrence and range a drag began with. Server updates during the drag can't change
    /// what the release seeks.
    private struct Drag {
        let queueID: String
        let itemID: String?
        let duration: Double
        var position: Double
    }

    private var shown: PlayerQueue? {
        queue ?? lastQueue
    }

    var body: some View {
        let duration = drag?.duration ?? shown?.duration ?? 0
        let reported = shown.map { clock.value($0, at: now) } ?? 0
        let elapsed = drag?.position ?? heldTarget(reported: reported) ?? reported
        let enabled = duration > 0 && model.canControl && model.supportsPlayback("seek")
        VStack(spacing: 6) {
            Scrubber(
                fraction: duration > 0 ? min(1, max(0, elapsed / duration)) : 0,
                active: drag != nil,
                enabled: enabled || drag != nil,
                onChange: { fraction in
                    guard let shown, duration > 0 else { return }
                    if drag == nil {
                        guard enabled else { return }
                        drag = Drag(queueID: shown.id, itemID: shown.itemID, duration: shown.duration, position: 0)
                        PlaybackDiagnostics.log("scrubber began queue=\(shown.id) item=\(shown.itemID ?? "-")")
                    }
                    drag?.position = fraction * (drag?.duration ?? duration)
                },
                onEnd: { commit() }
            )
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(elapsed)) of \(formatTime(duration))")
            .accessibilityAdjustableAction { direction in
                guard enabled, let shown else { return }
                let step = direction == .increment ? 15.0 : -15.0
                let target = min(max(0, elapsed + step), max(0, duration - 1))
                seek(target, queueID: shown.id, itemID: shown.itemID)
            }
            HStack {
                Text(formatTime(elapsed))
                Spacer()
                Text(duration > 0 ? "−\(formatTime(max(0, duration - elapsed)))" : "Live")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(drag == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityHidden(true)
        }
        // Advance the clock while playing; a paused clock needs no timer.
        .task(id: (shown?.isPlaying ?? false) && drag == nil) {
            guard shown?.isPlaying == true, drag == nil else { now = .now; return }
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onAppear { lastQueue = queue }
        .onChange(of: queue?.id) { _, _ in occurrenceChanged() }
        .onChange(of: queue?.itemID) { _, _ in occurrenceChanged() }
        .onChange(of: queue) { _, value in
            if let value {
                lastQueue = value
            }
        }
    }

    /// After a release, a speaker may report its old position, or zero, until it rebuilds its
    /// stream. Show the target, advancing while playing, until the report catches up.
    private func heldTarget(reported: Double) -> Double? {
        guard let released, released.itemID == shown?.itemID else { return nil }
        let age = now.timeIntervalSince(released.at)
        let target = released.value + (shown?.isPlaying == true ? max(0, age) : 0)
        guard age < 5, abs(reported - target) > 1.5 else { return nil }
        return min(target, drag?.duration ?? shown?.duration ?? target)
    }

    private func occurrenceChanged() {
        // A nil queue is a gap, not a new song; the drag and clock continue.
        guard let queue else { return }
        if let drag, drag.queueID != queue.id || drag.itemID != queue.itemID {
            PlaybackDiagnostics.log("scrubber dropped: song changed")
            self.drag = nil
        }
        if released?.itemID != queue.itemID {
            released = nil
        }
        clock = PlaybackClock(); now = .now
    }

    private func commit() {
        guard let drag else { return }
        self.drag = nil
        let target = min(drag.position, max(0, drag.duration - 1)).rounded()
        PlaybackDiagnostics.log("scrubber released target=\(target)")
        released = (drag.itemID, target, .now)
        now = .now
        seek(target, queueID: drag.queueID, itemID: drag.itemID)
    }

    private func seek(_ seconds: Double, queueID: String, itemID: String?) {
        Task {
            await model.queueCommand(
                "seek", args: ["position": .number(seconds)], queueID: queueID, expectedItemID: itemID
            )
        }
    }
}

/// A playback scrubber that owns its gesture, as the system player's does: the bar thickens
/// while dragged, a touch anywhere on it jumps there, and a release commits exactly once.
private struct Scrubber: View {
    let fraction: Double
    let active: Bool
    let enabled: Bool
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @GestureState private var touching = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // While dragged, the knob swells into clearer glass, as the system slider's does.
            let knob = active ? CGSize(width: 52, height: 32) : CGSize(width: 34, height: 22)
            // The knob stays inside the track at both ends.
            let x = min(max(width * fraction, knob.width / 2), max(knob.width / 2, width - knob.width / 2))
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18))
                    .frame(height: active ? 8 : 5)
                Capsule()
                    .fill(.primary.opacity(enabled ? 0.85 : 0.3))
                    .frame(width: min(width, max(0, width * fraction)), height: active ? 8 : 5)
                    // Position follows playback directly; only the drag state animates.
                    .animation(nil, value: fraction)
                if enabled {
                    Capsule()
                        .fill(.clear)
                        .frame(width: knob.width, height: knob.height)
                        .glassEffect(active ? .clear.interactive() : .regular.interactive(), in: .capsule)
                        .shadow(color: .black.opacity(active ? 0.2 : 0.12), radius: active ? 6 : 2, y: 1)
                        .position(x: x, y: proxy.size.height / 2)
                        .animation(nil, value: fraction)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.spring(duration: 0.35, bounce: 0.35), value: active)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        guard enabled, width > 0 else { return }
                        onChange(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { _ in onEnd() }
            )
            .onChange(of: touching) { _, isTouching in
                // The system can end a gesture without onEnded (an interruption, a sheet).
                // Committing is idempotent, so whichever arrives first seeks once.
                if !isTouching {
                    onEnd()
                }
            }
        }
        .frame(height: 32)
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

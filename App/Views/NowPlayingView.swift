import SwiftUI
import MusicAssistantCore
#if os(iOS)
import AVKit
#endif

struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 12) {
            Button { model.showNowPlaying = true } label: {
                HStack(spacing: 12) {
                    ArtworkView(item: model.current, cornerRadius: 7).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.current?.name ?? "Not Playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(model.selectedPlayer?.name ?? "Choose a player").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("miniPlayer")
            Button { Task { await model.togglePlayback() } } label: {
                Image(systemName: model.queue?.isPlaying == true ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 44)
            }.buttonStyle(.plain).disabled(!model.canControl)
                .accessibilityLabel(model.queue?.isPlaying == true ? "Pause" : "Play")
            Button { model.showPlayers = true } label: { Image(systemName: "hifispeaker.2").frame(width: 40, height: 44) }
                .buttonStyle(.plain).accessibilityLabel("Choose player")
        }
        .padding(.vertical, 6)
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingQueue = false
    @State private var showingPlayers = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    ArtworkView(item: model.current, cornerRadius: 18)
                        .frame(maxWidth: min(340, max(180, geometry.size.height * 0.36)))
                        .shadow(color: .black.opacity(0.12), radius: 20, y: 12)
                        .padding(.top, 16)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.current?.name ?? "Ready when you are").font(.title2.bold())
                        Text(model.current?.subtitle ?? "Choose something from your library or search.")
                            .font(.title3).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let queue = model.queue { PlaybackProgressView(queue: queue) }
                    HStack(spacing: 38) {
                        Button { Task { await model.playback("previous") } } label: { Image(systemName: "backward.fill").font(.title) }
                            .accessibilityLabel("Previous track")
                        Button { Task { await model.togglePlayback() } } label: {
                            Image(systemName: model.queue?.isPlaying == true ? "pause.fill" : "play.fill")
                                .font(.system(size: 42)).frame(width: 70, height: 70)
                        }.accessibilityLabel(model.queue?.isPlaying == true ? "Pause" : "Play")
                        Button { Task { await model.playback("next") } } label: { Image(systemName: "forward.fill").font(.title) }
                            .accessibilityLabel("Next track")
                    }.buttonStyle(.plain).disabled(!model.canControl)
                    if let player = model.selectedPlayer, player.volume != nil { PlayerVolume(player: player) }
                    HStack(spacing: 28) {
                        Button {
                            Task { await model.queueCommand("shuffle", args: ["shuffle_enabled": .bool(!(model.queue?.shuffle ?? false))]) }
                        } label: { Image(systemName: "shuffle").foregroundStyle(model.queue?.shuffle == true ? Color.accentColor : .secondary) }
                        .accessibilityLabel("Shuffle").accessibilityValue(model.queue?.shuffle == true ? "On" : "Off")
                        Spacer()
                        Button { showingPlayers = true } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "hifispeaker.2.fill")
                                Text(model.selectedPlayer?.name ?? "Choose Player").font(.caption).lineLimit(1)
                            }
                        }
                        #if os(iOS)
                        if model.selectedPlayerID == model.local.clientID, model.local.isConnected {
                            RoutePicker().frame(width: 32, height: 40).accessibilityLabel("Audio output")
                        }
                        #endif
                        Spacer()
                        Button { showingQueue.toggle() } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel("Playing next")
                        Button {
                            let next = model.queue?.repeatMode == "off" ? "all" : model.queue?.repeatMode == "all" ? "one" : "off"
                            Task { await model.queueCommand("repeat", args: ["repeat_mode": .string(next)]) }
                        } label: {
                            Image(systemName: model.queue?.repeatMode == "one" ? "repeat.1" : "repeat")
                                .foregroundStyle(model.queue?.repeatMode != "off" && model.queue != nil ? Color.accentColor : .secondary)
                        }.accessibilityLabel("Repeat").accessibilityValue(model.queue?.repeatMode ?? "off")
                    }.font(.title3).buttonStyle(.plain)
                }
                .frame(maxWidth: 440).padding(28).frame(maxWidth: .infinity)
            }
            }
            .navigationTitle("Now Playing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingQueue) { QueueView() }
            .sheet(isPresented: $showingPlayers) { NavigationStack { PlayersView(isSheet: true) }.presentationDetents([.medium, .large]) }
        }
        .presentationDragIndicator(.visible)
        #if os(iOS)
        .presentationSizing(.page)
        #endif
        #if os(macOS)
        .frame(width: 520, height: 780)
        #endif
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
                Slider(value: Binding(get: { elapsed }, set: { position = $0 }), in: 0...max(1, queue.duration)) { Text("Playback position") } onEditingChanged: { active in
                    if active { position = queue.elapsed() }
                    scrubbing = active
                    if !active { Task { await model.queueCommand("seek", args: ["position": .number(position.rounded())]) } }
                }
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

struct QueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if model.queueItems.isEmpty { ContentUnavailableView("Nothing Up Next", systemImage: "music.note.list") }
                ForEach(model.queueItems) { entry in
                    Button { Task { await model.queueCommand("play_index", args: ["index": .string(entry.id)]) } } label: {
                        HStack {
                            ArtworkView(item: entry.media).frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(entry.media.name).foregroundStyle(.primary)
                                Text(entry.media.subtitle).foregroundStyle(.secondary).font(.subheadline)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .navigationTitle("Playing Next")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.loadQueueItems() }
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
    }
}

#if os(iOS)
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
#endif

import AVFoundation
import MediaPlayer
import MusicAssistantCore
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class SystemMedia {
    private weak var model: AppModel?
    private var controlsLocalPlayback = false
    private var clearedLocal = false
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var publication = NowPlayingPublication()
    #if os(iOS)
        private var remotePublisher: AnyObject?
    #endif
    private var observers: [NSObjectProtocol] = []
    init(model: AppModel) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { [weak self] _ in await self?.sendPlayback("play") }
        register(center.pauseCommand) { [weak self] _ in await self?.sendPlayback("pause") }
        register(center.togglePlayPauseCommand) { [weak self] _ in await self?.sendPlayback("toggle") }
        register(center.nextTrackCommand) { [weak self] _ in await self?.sendPlayback("next") }
        register(center.previousTrackCommand) { [weak self] _ in await self?.sendPlayback("previous") }
        let target = center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                guard let self, let model = self.model,
                      model.connection == .connected || model.usesIndependentPlayback,
                      let queue = controlsLocalPlayback ? model.localQueue : model.queue,
                      position.isFinite, position >= 0, queue.duration > 0 else { return }
                await model.queueCommand("seek", args: ["position": .number(position.rounded())], queueID: queue.id)
            }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, target))
        clear()
        #if os(iOS)
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                PlaybackDiagnostics.log("audio interruption type=\(type.map(String.init) ?? "-") options=\(options)")
                Task { @MainActor [weak self] in
                    guard let model = self?.model else { return }
                    if type == AVAudioSession.InterruptionType.began.rawValue {
                        model.beginAudioInterruption()
                    } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                        await model.endAudioInterruption(
                            shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                        )
                    }
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                PlaybackAudioSession.logRouteChange(notification)
                let unplugged = reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if unplugged {
                    Task { @MainActor [weak self] in
                        await self?.model?.audioRouteDisconnected()
                    }
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.model?.audioServicesReset() }
            })
        #endif
    }

    private func sendPlayback(_ command: String) async {
        guard let model else { return }
        let queue = controlsLocalPlayback ? model.localQueue : model.queue
        let action = command == "toggle" ? (queue?.isPlaying == true ? "pause" : "play") : command
        if controlsLocalPlayback {
            await model.localPlayback(action)
        } else {
            await model.playback(action)
        }
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (AppModel) async -> Void) {
        let target = command.addTarget { @Sendable [weak self] _ in
            Task {
                @MainActor [weak self] in if let model = self?.model {
                    await action(model)
                }
            }
            return .success
        }
        targets.append((command, target))
    }

    func update() {
        guard let model, !model.isDemo else { clear(); return }
        // Keep system controls attached to audible local music when browsing another room,
        // including while the separate control WebSocket reconnects.
        let independent = model.usesIndependentPlayback && model.deviceAudio.state.current != nil &&
            (model.deviceAudio.wantsPlayback || model.isDeviceSelected || model.interruption.playback != nil)
        let useLocal = independent || model.local.isConnected && (model.localQueue?.isPlaying == true ||
            model.interruption.playback != nil || model.selectedPlayer.map { model.isLocalPlayer($0) } == true)
        let player = independent ? Player(.object([
            "player_id": .string(DevicePlaybackQueue.playerID), "name": .string("This Device"),
            "available": .bool(true),
        ])) : useLocal ? model.localPlaybackPlayer : model.selectedPlayer
        let currentQueue = useLocal ? model.localQueue : model.queue
        guard model.connection == .connected || useLocal, let player, player.available,
              let queue = currentQueue, let item = queue.current else { clear(); return }
        controlsLocalPlayback = useLocal
        #if os(iOS)
            let playsLocally = useLocal
            if #available(iOS 27, *) {
                if remotePublisher == nil {
                    remotePublisher = RemotePlaybackPublisher()
                }
                let publisher = remotePublisher as? RemotePlaybackPublisher
                if !playsLocally {
                    clearLocal()
                    if let server = model.server, queue.raw["ended"].bool != true {
                        publisher?.update(RemotePlaybackAttributes(server: server, player: player, queue: queue))
                    } else {
                        publisher?.update(nil)
                    }
                    return
                }
                publisher?.update(nil)
            }
            // iOS 26 needs an actual local audio session to own the system controls.
            guard playsLocally else { clearLocal(); return }
        #endif
        clearedLocal = false
        // Command and Now Playing changes are relayed to CarPlay and other accessories, and this
        // runs on every position tick. Write only what changed; see NowPlayingPublication.
        let center = MPRemoteCommandCenter.shared()
        Self.enable(center.playCommand, independent || player.supports("play", queue: queue))
        Self.enable(center.pauseCommand, independent || player.supports("pause", queue: queue))
        Self.enable(
            center.togglePlayPauseCommand,
            independent || player.supports(queue.isPlaying ? "pause" : "play", queue: queue)
        )
        Self.enable(center.nextTrackCommand, independent || player.supports("next", queue: queue))
        Self.enable(center.previousTrackCommand, independent || player.supports("previous", queue: queue))
        Self.enable(
            center.changePlaybackPositionCommand,
            queue.duration > 0 && (independent || player.supports("seek", queue: queue))
        )
        let artworkSource = model.artworkURL(for: item, pixels: 1024)
        let attachedArtwork = artworkURL == artworkSource ? artwork : nil
        let content = NowPlayingPublication.Content(
            title: item.name, artist: item.subtitle, duration: queue.duration, elapsed: queue.elapsed(),
            rate: queue.isPlaying ? (queue.raw["playback_speed"].double ?? 1) : 0,
            artwork: attachedArtwork == nil ? nil : artworkSource?.absoluteString
        )
        if publication.needsPublishing(content) {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: content.title,
                MPMediaItemPropertyArtist: content.artist,
                MPMediaItemPropertyPlaybackDuration: content.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: content.elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: content.rate,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            if let attachedArtwork {
                info[MPMediaItemPropertyArtwork] = attachedArtwork
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            PlaybackDiagnostics.log(
                "now playing published elapsed=\(String(format: "%.2f", content.elapsed)) rate=\(content.rate) " +
                    "artwork=\(content.artwork != nil)"
            )
            #if os(macOS)
                MPNowPlayingInfoCenter.default().playbackState = queue.isPlaying ? .playing : .paused
            #endif
        }
        loadArtwork(artworkSource)
    }

    private static func enable(_ command: MPRemoteCommand, _ enabled: Bool) {
        if command.isEnabled != enabled {
            command.isEnabled = enabled
        }
    }

    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkTask?.cancel()
        artworkURL = url; artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            let data: Data? = if url.isFileURL {
                try? await Task.detached { try Data(contentsOf: url) }.value
            } else {
                try? await URLSession.shared.data(from: url).0
            }
            guard let data, !Task.isCancelled, let self, artworkURL == url else { return }
            artwork = SystemMediaArtwork.make(data: data)
            update()
        }
    }

    func clear() {
        #if os(iOS)
            if #available(iOS 27, *) {
                if remotePublisher == nil {
                    remotePublisher = RemotePlaybackPublisher()
                }
                (remotePublisher as? RemotePlaybackPublisher)?.update(nil)
            }
        #endif
        clearLocal()
    }

    private func clearLocal() {
        // Hand off the process-global MediaPlayer publication once. Remote updates
        // must leave the remote session's metadata and commands to NowPlaying.
        guard !clearedLocal else { return }
        clearedLocal = true
        controlsLocalPlayback = false
        artworkTask?.cancel(); artworkTask = nil
        artwork = nil; artworkURL = nil
        publication.reset()
        targets.forEach { $0.0.isEnabled = false }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    isolated deinit {
        artworkTask?.cancel()
        for (command, target) in targets {
            command.removeTarget(target)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

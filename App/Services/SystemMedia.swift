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
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    #if os(iOS)
    private var remotePublisher: AnyObject?
    #endif
    private var observers: [NSObjectProtocol] = []
    init(model: AppModel) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { await $0.playback("play") }
        register(center.pauseCommand) { await $0.playback("pause") }
        register(center.togglePlayPauseCommand) { await $0.togglePlayback() }
        register(center.nextTrackCommand) { await $0.playback("next") }
        register(center.previousTrackCommand) { await $0.playback("previous") }
        let target = center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                guard let model = self?.model, model.canControl, let queue = model.queue,
                      position.isFinite, position >= 0, queue.duration > 0 else { return }
                await model.queueCommand("seek", args: ["position": .number(position.rounded())], queueID: queue.id)
            }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, target))
        clear()
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor [weak self] in
                guard let model = self?.model, model.local.isConnected else { return }
                if began { await model.localPlayback("pause") }
                // Resume stays user-driven so another room is never resumed unexpectedly.
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let unplugged = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if unplugged { Task { @MainActor [weak self] in
                guard let model = self?.model, model.local.isConnected else { return }
                await model.localPlayback("pause")
            } }
        })
        #endif
    }
    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (AppModel) async -> Void) {
        let target = command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in if let model = self?.model { await action(model) } }
            return .success
        }
        targets.append((command, target))
    }
    func update() {
        guard let model, !model.isDemo, model.connection == .connected,
              let player = model.selectedPlayer, player.available,
              let queue = model.queue, let item = queue.current else { clear(); return }
        #if os(iOS)
        let playsLocally = model.local.isConnected && model.localQueue?.id == queue.id
        if #available(iOS 27, *) {
            if remotePublisher == nil { remotePublisher = RemotePlaybackPublisher() }
            let publisher = remotePublisher as? RemotePlaybackPublisher
            if !playsLocally {
                clearLocal()
                if let server = model.server, queue.raw["ended"].bool != true {
                    publisher?.update(RemotePlaybackAttributes(server: server, player: player, queue: queue))
                } else { publisher?.update(nil) }
                return
            }
            publisher?.update(nil)
        }
        // iOS 26 needs an actual local audio session to own the system controls.
        guard playsLocally else { clearLocal(); return }
        #endif
        targets.forEach { $0.0.isEnabled = true }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = queue.duration > 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyPlaybackDuration: queue.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: queue.elapsed(),
            MPNowPlayingInfoPropertyPlaybackRate: queue.isPlaying ? (queue.raw["playback_speed"].double ?? 1) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artwork, artworkURL == item.artworkURL(server: model.server) { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(item.artworkURL(server: model.server))
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = queue.isPlaying ? .playing : .paused
        #endif
    }
    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkTask?.cancel()
        artworkURL = url; artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            guard let self, self.artworkURL == url else { return }
            self.artwork = SystemMediaArtwork.make(data: data)
            self.update()
        }
    }
    func clear() {
        #if os(iOS)
        if #available(iOS 27, *) {
            if remotePublisher == nil { remotePublisher = RemotePlaybackPublisher() }
            (remotePublisher as? RemotePlaybackPublisher)?.update(nil)
        }
        #endif
        clearLocal()
    }
    private func clearLocal() {
        artworkTask?.cancel(); artworkTask = nil
        artwork = nil; artworkURL = nil
        targets.forEach { $0.0.isEnabled = false }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }
    isolated deinit {
        artworkTask?.cancel()
        for (command, target) in targets { command.removeTarget(target) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

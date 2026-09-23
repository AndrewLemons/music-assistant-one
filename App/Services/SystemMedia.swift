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
    private var observers: [NSObjectProtocol] = []
    init(model: AppModel) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { await $0.localPlayback("play") }
        register(center.pauseCommand) { await $0.localPlayback("pause") }
        register(center.togglePlayPauseCommand) { await $0.localPlayback($0.localQueue?.isPlaying == true ? "pause" : "play") }
        register(center.nextTrackCommand) { await $0.localPlayback("next") }
        register(center.previousTrackCommand) { await $0.localPlayback("previous") }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                guard let model = self?.model, let queue = model.localQueue else { return }
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
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in if let model = self?.model { await action(model) } }
            return .success
        }
        targets.append((command, target))
    }
    func update() {
        guard let model, !model.isDemo, model.local.isConnected,
              let queue = model.localQueue, let item = queue.current else { clear(); return }
        targets.forEach { $0.0.isEnabled = true }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = queue.duration > 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyPlaybackDuration: queue.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: queue.elapsed(),
            MPNowPlayingInfoPropertyPlaybackRate: queue.isPlaying ? 1.0 : 0.0,
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
            #if os(macOS)
            guard let image = NSImage(data: data) else { return }
            #else
            guard let image = UIImage(data: data) else { return }
            #endif
            guard let self, self.artworkURL == url else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.update()
        }
    }
    func clear() {
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

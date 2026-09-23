#if os(iOS)
import Foundation
import MusicAssistantCore
import NowPlaying
import OSLog
import UIKit

/// Serializes starts, updates and ends so rapid player changes cannot revive an old session.
@available(iOS 27, *)
@MainActor
final class RemotePlaybackPublisher {
    private var desired: RemotePlaybackAttributes?
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var session: RemoteMediaSession<RemotePlaybackAttributes>?
    private var requestedPrimary = false
    private var recoveredSessions = false
    private let logger = Logger(subsystem: "com.lemonyclick.music-assistant-one", category: "RemotePlayback")

    func update(_ attributes: RemotePlaybackAttributes?) {
        desired = attributes
        revision += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.reconcile() }
    }

    private func reconcile() async {
        defer { worker = nil }
        repeat {
            let currentRevision = revision
            let target = desired
            do {
                // Clear sessions left by a prior app process, including a previously selected room.
                if !recoveredSessions {
                    for previous in try await RemoteMediaSession<RemotePlaybackAttributes>.sessions() {
                        try await previous.end()
                    }
                    recoveredSessions = true
                }
                if let session, session.id != target?.id {
                    try await session.end()
                    self.session = nil
                    requestedPrimary = false
                }
                if let target {
                    if let session { try await session.update(target) }
                    else if PlayerQueue(target.queue).isPlaying {
                        session = try await RemoteMediaSession.start(attributes: target)
                    }
                    if currentRevision == revision, UIApplication.shared.applicationState == .active,
                       let session, !requestedPrimary {
                        requestedPrimary = true
                        try await session.requestToBecomeSystemPrimary()
                    }
                }
            } catch {
                logger.error("Remote playback session update failed: \(error.localizedDescription, privacy: .public)")
            }
            if currentRevision == revision { return }
        } while !Task.isCancelled
    }
}
#endif

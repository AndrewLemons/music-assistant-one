#if os(iOS)
    import Foundation
    import MusicAssistantCore
    import NowPlaying
    import OSLog
    import UIKit

    @available(iOS 27, *)
    @MainActor
    protocol RemotePlaybackPublication: AnyObject {
        var id: String { get }
        func update(_ attributes: RemotePlaybackAttributes) async throws
        func end() async throws
        func requestToBecomeSystemPrimary() async throws
    }

    @available(iOS 27, *)
    extension RemoteMediaSession: RemotePlaybackPublication where Attributes == RemotePlaybackAttributes {}

    /// Serializes starts, updates and ends so rapid player changes cannot revive an old session.
    @available(iOS 27, *)
    @MainActor
    final class RemotePlaybackPublisher {
        private var desired: RemotePlaybackAttributes?
        private var revision = 0
        private var worker: Task<Void, Never>?
        private var session: (any RemotePlaybackPublication)?
        private let recover: () async throws -> [any RemotePlaybackPublication]
        private let start: (RemotePlaybackAttributes) async throws -> any RemotePlaybackPublication
        private let isForeground: () -> Bool
        private var requestedPrimary = false
        private var recoveredSessions = false
        private let logger = Logger(subsystem: "com.lemonyclick.music-assistant-one", category: "RemotePlayback")

        init(
            recover: @escaping () async throws -> [any RemotePlaybackPublication] = {
                try await RemoteMediaSession<RemotePlaybackAttributes>.sessions()
            },
            start: @escaping (RemotePlaybackAttributes) async throws -> any RemotePlaybackPublication = {
                try await RemoteMediaSession.start(attributes: $0)
            },
            isForeground: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }
        ) {
            self.recover = recover
            self.start = start
            self.isForeground = isForeground
        }

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
                        for previous in try await recover() {
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
                        if let session {
                            try await session.update(target)
                        } else if PlayerQueue(target.queue).current != nil {
                            session = try await start(target)
                            PlaybackDiagnostics.log("remote session started player=\(target.playerID)")
                        }
                        if currentRevision == revision, isForeground(),
                           let session, !requestedPrimary
                        {
                            try await session.requestToBecomeSystemPrimary()
                            PlaybackDiagnostics.log("remote session requested primary")
                            requestedPrimary = isForeground()
                        }
                    }
                } catch {
                    PlaybackDiagnostics.log("remote session update failed: \(error)")
                    logger
                        .error("Remote playback session update failed: \(error.localizedDescription, privacy: .public)")
                }
                if currentRevision == revision {
                    return
                }
            } while !Task.isCancelled
        }
    }
#endif

import Foundation

/// Captures the actual local queue, independently of the room selected in the UI.
public struct InterruptedPlayback: Equatable, Sendable {
    public let playerID: String
    public let queueID: String
    public let itemID: String

    public init?(playerID: String?, queue: PlayerQueue?) {
        guard let playerID, let queue, queue.isPlaying, let item = queue.current else { return nil }
        self.playerID = playerID
        queueID = queue.id
        itemID = queue.raw["current_item"]["queue_item_id"].string ?? item.id
    }

    public func matches(playerID: String?, queue: PlayerQueue?) -> Bool {
        guard self.playerID == playerID, let queue, queue.id == queueID,
              let item = queue.current, queue.raw["ended"].bool != true else { return false }
        return itemID == (queue.raw["current_item"]["queue_item_id"].string ?? item.id)
    }
}

/// Serializes interruption pause/resume and invalidates automatic resume on explicit user intent.
@MainActor
public final class PlaybackInterruption {
    public private(set) var isInterrupted = false
    public private(set) var isResuming = false
    public private(set) var playback: InterruptedPlayback?
    public private(set) var revision = UUID()
    private var endingRevision: UUID?
    private var pauseTask: Task<Bool, Never>?

    public init() {}

    public func begin(_ playback: InterruptedPlayback?, pause: @escaping @MainActor () async throws -> Void) {
        guard !isInterrupted else { return }
        isInterrupted = true
        isResuming = false
        revision = UUID()
        self.playback = playback
        pauseTask = Task {
            do { try await pause(); return true } catch { return false }
        }
    }

    public func end(shouldResume: Bool, resume: @MainActor (InterruptedPlayback) async throws -> Void) async throws {
        guard isInterrupted, endingRevision != revision else { return }
        let attempt = revision
        endingRevision = attempt
        defer {
            if endingRevision == attempt {
                endingRevision = nil
            }
        }
        let paused = await pauseTask?.value == true
        guard attempt == revision else { return }
        isInterrupted = false
        pauseTask = nil
        let target = playback
        guard shouldResume, paused, let target else { playback = nil; return }
        isResuming = true
        defer {
            if attempt == revision {
                isResuming = false
                playback = nil
            }
        }
        try await resume(target)
    }

    public func cancelResume() {
        playback = nil
    }

    public func reset() {
        revision = UUID()
        isInterrupted = false
        isResuming = false
        playback = nil
        pauseTask?.cancel()
        pauseTask = nil
    }
}

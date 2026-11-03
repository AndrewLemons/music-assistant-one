import Foundation
import Observation

/// Optimistic transport control for server-owned queues.
///
/// Every command updates the prediction immediately and is sent by one ordered writer per
/// queue, so the interface never waits for a round trip and taps are never dropped. Queued
/// Next and Previous taps combine into one skip; repeated play/pause, seek, shuffle and repeat
/// requests keep only the latest. Server snapshots reconcile the prediction field by field;
/// a failed command clears it and reports the error.
@MainActor @Observable
public final class TransportControl {
    public struct Target: Hashable, Sendable {
        public let queueID: String
        public let playerID: String
        public init(queueID: String, playerID: String) {
            self.queueID = queueID; self.playerID = playerID
        }

        /// Resolve at send time: a linked protocol or group member does not own the queue.
        public func resolvingActiveQueue(_ value: JSONValue, expectedItemID: String? = nil) throws -> Target {
            guard let id = value["queue_id"].string, !id.isEmpty, value["active"].bool != false else {
                throw MAError.message("This player's queue is no longer active.")
            }
            if let expectedItemID, PlayerQueue(value).itemID != expectedItemID {
                throw MAError.message("The song changed before this seek could be sent.")
            }
            return Target(queueID: id, playerID: playerID)
        }
    }

    public enum Command: Sendable, Equatable {
        case play, pause, stop, next, previous
        case select(entryID: String)
        case seek(Double)
        case shuffle(Bool)
        case repeatMode(String)
    }

    public private(set) var predictions: [String: TransportPrediction] = [:]

    @ObservationIgnored public var send: @MainActor (Target, Command) async throws -> Void = { _, _ in }
    /// Reads the server's queue after acknowledged commands; the result arrives through `update`.
    @ObservationIgnored public var refresh: @MainActor (Target) async -> Void = { _ in }
    @ObservationIgnored public var onError: @MainActor (any Error) -> Void = { _ in }
    @ObservationIgnored public var onChange: @MainActor () -> Void = {}

    @ObservationIgnored public var grace: TimeInterval = 2.5
    @ObservationIgnored public var timeout: TimeInterval = 10
    /// Starting new music can take a speaker several seconds.
    @ObservationIgnored public var startGrace: TimeInterval = 8
    @ObservationIgnored public var startTimeout: TimeInterval = 20
    @ObservationIgnored public var pollInterval: Duration = .milliseconds(400)

    private enum Work {
        case playing(Bool, stop: Bool)
        case skip(Int)
        /// Previous after the first seconds of a song: the server restarts it instead.
        case restart
        case select(String)
        case seek(Double)
        case shuffle(Bool)
        case repeatMode(String)
        case start(@MainActor () async throws -> Void)
        case additive(@MainActor () async throws -> Void)
    }

    private struct Operation {
        let sequence: Int
        let target: Target
        var itemID: String?
        var work: Work

        var changesItem: Bool {
            switch work {
            case .skip, .select, .start: true
            default: false
            }
        }
    }

    /// Music Assistant's `previous` restarts a song that has played at least this long.
    static let restartThreshold = 5.0

    @ObservationIgnored private var pending: [String: [Operation]] = [:]
    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var polls: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var targets: [String: Target] = [:]
    @ObservationIgnored private var confirmed: [String: PlayerQueue] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var generation = UUID()

    public init() {}

    /// The queue as the interface shows it. Without a server snapshot, a predicted song still
    /// appears under `fallbackID`.
    public func displayed(_ queue: PlayerQueue?, fallbackID: String? = nil) -> PlayerQueue? {
        guard let id = queue?.id ?? fallbackID, let prediction = predictions[id] else { return queue }
        if let queue {
            return prediction.applied(to: queue)
        }
        guard prediction.item != nil else { return nil }
        return prediction.applied(to: PlayerQueue(.object(["queue_id": .string(id), "state": .string("idle")])))
    }

    /// Records a server snapshot and settles the fields it confirms or supersedes.
    public func update(_ queue: PlayerQueue?) {
        guard let queue, !queue.id.isEmpty else { return }
        confirmed[queue.id] = queue
        reconcile(queue.id)
    }

    // MARK: Commands

    public func setPlaying(_ playing: Bool, target: Target) {
        enqueue(.playing(playing, stop: false), target: target) { prediction, sequence, date in
            prediction.playing = .init(playing, issued: date, sequence: sequence, grace: grace, timeout: timeout)
        }
    }

    public func stop(target: Target) {
        enqueue(.playing(false, stop: true), target: target) { prediction, sequence, date in
            prediction.playing = .init(false, issued: date, sequence: sequence, grace: grace, timeout: timeout)
        }
    }

    /// Skips by `offset` songs. `entries` is the queue or a window of it starting at `firstIndex`;
    /// without the destination in it, the command is still sent and only the server shows the result.
    public func skip(
        _ offset: Int,
        target: Target,
        entries: [QueueEntry],
        firstIndex: Int = 0,
        complete: Bool = false
    ) {
        guard offset != 0 else { return }
        let shown = displayed(confirmed[target.queueID], fallbackID: target.queueID)
        // Music Assistant restarts the current song when Previous arrives after its first
        // five seconds, and goes back a song otherwise. Show what it will do.
        if offset == -1, let shown, shown.elapsed() >= Self.restartThreshold,
           !(pending[target.queueID] ?? []).contains(where: \.changesItem)
        {
            let itemID = shown.itemID
            enqueue(.restart, target: target) { prediction, sequence, date in
                prediction.position = .init(0, issued: date, sequence: sequence, grace: timeout, timeout: timeout)
                prediction.positionItemID = itemID
            }
            return
        }
        let destination = TransportPrediction.destination(
            from: shown?.raw["current_item"]["queue_item_id"].string,
            by: offset,
            in: entries,
            firstIndex: firstIndex,
            repeatMode: shown?.repeatMode ?? "off",
            complete: complete
        )
        enqueue(.skip(offset), target: target) { prediction, sequence, date in
            guard let destination else { return }
            prediction.item = .init(
                .init(entry: destination.entry, index: destination.index),
                issued: date, sequence: sequence, grace: grace, timeout: timeout
            )
        }
    }

    public func select(_ entry: QueueEntry, index: Int?, target: Target) {
        enqueue(.select(entry.id), target: target) { prediction, sequence, date in
            prediction.item = .init(
                .init(entry: entry, index: index),
                issued: date, sequence: sequence, grace: grace, timeout: timeout
            )
        }
    }

    public func seek(_ position: Double, target: Target) {
        guard position.isFinite, position >= 0 else { return }
        enqueue(.seek(position), target: target) { prediction, sequence, date in
            prediction.position = .init(position, issued: date, sequence: sequence, grace: timeout, timeout: timeout)
            prediction.positionItemID = displayed(confirmed[target.queueID], fallbackID: target.queueID)?.itemID
        }
    }

    public func setShuffle(_ enabled: Bool, target: Target) {
        enqueue(.shuffle(enabled), target: target) { prediction, sequence, date in
            prediction.shuffle = .init(enabled, issued: date, sequence: sequence, grace: grace, timeout: timeout)
        }
    }

    public func setRepeat(_ mode: String, target: Target) {
        enqueue(.repeatMode(mode), target: target) { prediction, sequence, date in
            prediction.repeatMode = .init(mode, issued: date, sequence: sequence, grace: grace, timeout: timeout)
        }
    }

    /// Replaces what plays, in order with other commands for the queue. A newer start that
    /// arrives before this one is sent replaces it. A known first song shows immediately.
    public func start(
        _ media: MediaItem?,
        target: Target,
        replacing: Bool = true,
        work: @escaping @MainActor () async throws -> Void
    ) {
        enqueue(replacing ? .start(work) : .additive(work), target: target) { prediction, sequence, date in
            guard replacing, let media else { return }
            prediction.item = .init(
                .init(media: media), issued: date, sequence: sequence, grace: startGrace, timeout: startTimeout
            )
            prediction.playing = .init(
                true, issued: date, sequence: sequence, grace: startGrace, timeout: startTimeout
            )
        }
    }

    /// Drops queued commands and predictions, such as when the connection ends.
    public func cancel() {
        generation = UUID()
        workers.values.forEach { $0.cancel() }
        polls.values.forEach { $0.cancel() }
        expiry?.cancel(); expiry = nil
        workers = [:]; polls = [:]; pending = [:]; confirmed = [:]; targets = [:]
        if !predictions.isEmpty {
            predictions = [:]
            onChange()
        }
    }

    // MARK: Ordering

    /// A queued command absorbs a newer one of the same kind. Opposite skips can net to zero,
    /// which sends nothing but still settles the prediction.
    private func merge(_ queued: Work, with new: Work) -> Work? {
        switch (queued, new) {
        case (.playing, .playing), (.seek, .seek), (.shuffle, .shuffle), (.repeatMode, .repeatMode), (.start, .start):
            new
        case let (.skip(a), .skip(b)):
            .skip(a + b)
        default:
            nil
        }
    }

    private func enqueue(
        _ work: Work,
        target: Target,
        predict: (inout TransportPrediction, Int, Date) -> Void
    ) {
        let id = target.queueID
        targets[id] = target
        polls[id]?.cancel(); polls[id] = nil
        var queue = pending[id] ?? []
        var prediction = predictions[id] ?? TransportPrediction()
        let date = Date.now
        let changesItem = switch work {
        case .skip, .select, .start: true
        default: false
        }
        if changesItem {
            prediction.position = nil
            prediction.positionItemID = nil
            // A position in the song being skipped no longer applies.
            for operation in queue {
                if case .seek = operation.work {
                    prediction.discard(operation.sequence)
                }
            }
            queue.removeAll {
                if case .seek = $0.work {
                    true
                } else {
                    false
                }
            }
        }
        if let last = queue.last, last.target == target, let merged = merge(last.work, with: work) {
            queue[queue.count - 1].work = merged
            queue[queue.count - 1].itemID = displayed(confirmed[id], fallbackID: id)?.itemID
            predict(&prediction, last.sequence, date)
            commit(queue, prediction, for: id)
            return
        }
        sequence += 1
        queue.append(Operation(
            sequence: sequence, target: target,
            itemID: displayed(confirmed[id], fallbackID: id)?.itemID, work: work
        ))
        predict(&prediction, sequence, date)
        commit(queue, prediction, for: id)
        drain(id)
    }

    private func commit(_ queue: [Operation], _ prediction: TransportPrediction, for id: String) {
        pending[id] = queue
        store(prediction, for: id)
    }

    private func store(_ prediction: TransportPrediction, for id: String) {
        let value: TransportPrediction? = prediction.isEmpty ? nil : prediction
        guard predictions[id] != value else { return }
        predictions[id] = value
        scheduleExpiry()
        onChange()
    }

    private func drain(_ id: String) {
        guard workers[id] == nil else { return }
        let epoch = generation
        workers[id] = Task { [weak self] in
            await self?.run(id, epoch: epoch)
        }
    }

    private func run(_ id: String, epoch: UUID) async {
        // The play state this burst last requested, so play-pause-play sends one play.
        var requested: Bool?
        while generation == epoch, var queue = pending[id], !queue.isEmpty {
            let operation = queue.removeFirst()
            pending[id] = queue
            do {
                try await execute(operation, requested: &requested)
                guard generation == epoch else { return }
                var prediction = predictions[id] ?? TransportPrediction()
                prediction.acknowledge(operation.sequence)
                prediction.reconcile(with: confirmed[id])
                store(prediction, for: id)
            } catch {
                guard generation == epoch else { return }
                pending[id] = []
                store(TransportPrediction(), for: id)
                if !(error is CancellationError) {
                    onError(error)
                }
            }
        }
        guard generation == epoch else { return }
        workers[id] = nil
        poll(id, epoch: epoch)
    }

    private func execute(_ operation: Operation, requested: inout Bool?) async throws {
        let target = operation.target
        switch operation.work {
        case let .playing(playing, stop):
            guard stop || requested != playing else { return }
            try await send(target, stop ? .stop : playing ? .play : .pause)
            requested = stop ? nil : playing
        case let .skip(offset):
            requested = nil
            if abs(offset) > 1, let item = predictions[target.queueID]?.item, item.sequence == operation.sequence,
               let entryID = item.value.entryID
            {
                try await send(target, .select(entryID: entryID))
            } else {
                for _ in 0 ..< abs(offset) {
                    try await send(target, offset > 0 ? .next : .previous)
                }
            }
        case .restart:
            requested = nil
            try await send(target, .previous)
        case let .select(entryID):
            requested = nil
            try await send(target, .select(entryID: entryID))
        case let .seek(position):
            // A queued drag from the preceding occurrence must never seek the next song.
            guard operation.itemID == nil || operation.itemID == displayed(confirmed[target.queueID])?.itemID
            else { return }
            try await send(target, .seek(position))
        case let .shuffle(enabled): try await send(target, .shuffle(enabled))
        case let .repeatMode(mode): try await send(target, .repeatMode(mode))
        case let .start(work):
            try await work()
            requested = true
        case let .additive(work):
            try await work()
            requested = nil
        }
    }

    // MARK: Reconciliation

    /// Some speakers acknowledge before they publish new state. Read it a few times during
    /// the grace period instead of waiting for an event.
    private func poll(_ id: String, epoch: UUID) {
        guard predictions[id] != nil, let target = targets[id] else { return }
        polls[id]?.cancel()
        polls[id] = Task { [weak self] in
            for attempt in 0 ..< 8 {
                guard let self, generation == epoch, !Task.isCancelled, predictions[id] != nil else { return }
                if attempt > 0 {
                    do { try await Task.sleep(for: pollInterval) } catch { return }
                }
                guard generation == epoch, !Task.isCancelled, workers[id] == nil else { return }
                await refresh(target)
            }
        }
    }

    private func reconcile(_ id: String) {
        guard var prediction = predictions[id] else { return }
        prediction.reconcile(with: confirmed[id])
        store(prediction, for: id)
    }

    private func scheduleExpiry() {
        expiry?.cancel(); expiry = nil
        guard let deadline = predictions.values.compactMap(\.deadline).min() else { return }
        let epoch = generation
        expiry = Task { [weak self] in
            let delay = max(0.01, deadline.timeIntervalSinceNow + 0.01)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == epoch else { return }
            expiry = nil
            for id in Array(predictions.keys) {
                reconcile(id)
            }
            if expiry == nil {
                scheduleExpiry()
            }
        }
    }
}

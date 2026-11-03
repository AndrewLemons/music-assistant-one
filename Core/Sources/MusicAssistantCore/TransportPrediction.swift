import Foundation

/// What the interface shows before the server confirms transport commands.
///
/// Each field reconciles on its own. Before its command is acknowledged, no snapshot clears
/// it, because the server may still be reporting the earlier state. After acknowledgement, a
/// matching snapshot clears it at once and a different one supersedes it after a grace period.
/// A field that is never acknowledged expires.
public struct TransportPrediction: Sendable, Equatable {
    public struct Expectation<Value: Sendable & Equatable>: Sendable, Equatable {
        public var value: Value
        public var issued: Date
        /// The command that set this value. Only that command's acknowledgement settles it.
        public var sequence: Int
        public var acknowledged: Date?
        /// How long after acknowledgement a different server state is still treated as stale.
        public var grace: TimeInterval
        /// How long an unacknowledged value is shown.
        public var timeout: TimeInterval

        public init(
            _ value: Value,
            issued: Date,
            sequence: Int,
            grace: TimeInterval = 2.5,
            timeout: TimeInterval = 10
        ) {
            self.value = value; self.issued = issued; self.sequence = sequence
            self.grace = grace; self.timeout = timeout
        }

        var deadline: Date {
            acknowledged.map { min($0.addingTimeInterval(grace), issued.addingTimeInterval(timeout)) } ??
                issued.addingTimeInterval(timeout)
        }
    }

    /// A predicted current song. A queue entry identifies one occurrence; a song that is just
    /// starting has no entry until the server creates it, so it matches by URI.
    public struct Item: Sendable, Equatable {
        public var entryID: String?
        public var uri: String
        public var index: Int?
        /// In the shape of a queue's `current_item`.
        public var raw: JSONValue

        public init(entry: QueueEntry, index: Int?) {
            entryID = entry.id; uri = entry.media.uri; self.index = index; raw = entry.raw
        }

        public init(media: MediaItem) {
            entryID = nil; uri = media.uri; index = nil
            raw = .object([
                "name": .string(media.name), "duration": .number(media.duration), "media_item": media.raw,
            ])
        }
    }

    public var playing: Expectation<Bool>?
    public var item: Expectation<Item>?
    public var position: Expectation<Double>?
    /// Queue occurrence the seek belongs to; repeated songs have distinct IDs.
    public var positionItemID: String?
    public var shuffle: Expectation<Bool>?
    public var repeatMode: Expectation<String>?

    /// Position differences below this are clock drift, not a different state.
    public static let positionTolerance: TimeInterval = 0.75

    public init() {}

    public var isEmpty: Bool {
        playing == nil && item == nil && position == nil && shuffle == nil && repeatMode == nil
    }

    /// The earliest time a field can expire without a new snapshot.
    public var deadline: Date? {
        [playing?.deadline, item?.deadline, position?.deadline, shuffle?.deadline, repeatMode?.deadline]
            .compactMap(\.self).min()
    }

    private enum Event {
        case item(Item), position(Double), playing(Bool)
    }

    /// The server snapshot with predicted fields applied. The playback clock replays predicted
    /// events in the order they were issued, so a pause freezes the position at the tap and a
    /// skip restarts the clock at zero.
    public func applied(to queue: PlayerQueue) -> PlayerQueue {
        guard !isEmpty else { return queue }
        var patch: [String: JSONValue] = [:]
        if let shuffle {
            patch["shuffle_enabled"] = .bool(shuffle.value)
        }
        if let repeatMode {
            patch["repeat_mode"] = .string(repeatMode.value)
        }
        var events: [(date: Date, sequence: Int, event: Event)] = []
        if let item {
            events.append((item.issued, item.sequence, .item(item.value)))
        }
        let seekApplies = positionItemID == nil || positionItemID == (item?.value.entryID ?? queue.itemID)
        if let position, seekApplies {
            events.append((position.issued, position.sequence, .position(position.value)))
        }
        if let playing {
            events.append((playing.issued, playing.sequence, .playing(playing.value)))
        }
        events.sort { ($0.date, $0.sequence) < ($1.date, $1.sequence) }
        if let start = events.first?.date {
            let speed = queue.raw["playback_speed"].double ?? 1
            var running = queue.isPlaying
            var anchor = queue.elapsed(at: start)
            var anchorDate = start
            for (date, _, event) in events {
                if running {
                    anchor += max(0, date.timeIntervalSince(anchorDate)) * speed
                }
                anchorDate = date
                switch event {
                case let .item(item):
                    anchor = 0
                    patch["current_item"] = item.raw
                    patch["current_index"] = item.index.map { .number(Double($0)) } ?? .null
                    patch["ended"] = .bool(false)
                case let .position(value): anchor = value
                case let .playing(value): running = value
                }
            }
            patch["elapsed_time"] = .number(anchor)
            patch["resume_pos"] = .number(anchor)
            patch["elapsed_time_last_updated"] = .number(anchorDate.timeIntervalSince1970)
            if playing != nil {
                patch["state"] = .string(running ? "playing" : "paused")
            }
        }
        if item != nil {
            // A selected song has not started until its own clock arrives. Advancing the old
            // player's clock here makes confirmation move the new song backward.
            patch["playback_speed"] = .number(0)
        }
        if let position, seekApplies, item == nil || position.sequence > (item?.sequence ?? 0) {
            // Rebuilding a Sendspin flow can take seconds. Keep the requested position,
            // rather than inventing playback during that wait and snapping back on confirmation.
            patch["elapsed_time"] = .number(position.value)
            patch["resume_pos"] = .number(position.value)
            patch["playback_speed"] = .number(0)
        }
        let anchorDate = events.last?.date ?? queue.receivedAt
        return queue.predicting(patch, at: anchorDate)
    }

    public mutating func acknowledge(_ sequence: Int, at date: Date = .now) {
        if playing?.sequence == sequence {
            playing?.acknowledged = date
        }
        if item?.sequence == sequence {
            item?.acknowledged = date
        }
        if position?.sequence == sequence {
            position?.acknowledged = date
        }
        if shuffle?.sequence == sequence {
            shuffle?.acknowledged = date
        }
        if repeatMode?.sequence == sequence {
            repeatMode?.acknowledged = date
        }
    }

    /// Removes the fields a withdrawn command set.
    public mutating func discard(_ sequence: Int) {
        if playing?.sequence == sequence {
            playing = nil
        }
        if item?.sequence == sequence {
            item = nil
        }
        if position?.sequence == sequence {
            position = nil
        }
        if shuffle?.sequence == sequence {
            shuffle = nil
        }
        if repeatMode?.sequence == sequence {
            repeatMode = nil
        }
    }

    /// Clears fields that the server confirms or supersedes, and fields that expired.
    public mutating func reconcile(with confirmed: PlayerQueue?, at date: Date = .now) {
        if let positionItemID, let confirmed, item == nil, confirmed.itemID != positionItemID {
            position = nil
            self.positionItemID = nil
        }
        let predicted = confirmed.map(applied)
        let confirmedEntry = confirmed?.raw["current_item"]["queue_item_id"].string
        func settle<Value>(_ field: inout Expectation<Value>?, matches: (Value) -> Bool) {
            guard let expectation = field else { return }
            if date >= expectation.issued.addingTimeInterval(expectation.timeout) {
                field = nil; return
            }
            guard let acknowledged = expectation.acknowledged else { return }
            if matches(expectation.value) || date >= acknowledged.addingTimeInterval(expectation.grace) {
                field = nil
            }
        }
        settle(&playing) { confirmed?.isPlaying == $0 }
        settle(&item) { item in
            guard let confirmed else { return false }
            if let entryID = item.entryID {
                return entryID == confirmedEntry
            }
            return confirmed.current?.uri == item.uri
        }
        settle(&position) { _ in
            guard let confirmed, let predicted,
                  predicted.raw["current_item"]["queue_item_id"] == confirmed.raw["current_item"]["queue_item_id"]
            else { return false }
            return abs(predicted.elapsed(at: date) - confirmed.elapsed(at: date)) < Self.positionTolerance
        }
        settle(&shuffle) { confirmed?.shuffle == $0 }
        settle(&repeatMode) { confirmed?.repeatMode == $0 }
    }

    /// The entry a relative skip lands on, from the current entry within `entries`.
    /// `firstIndex` is the queue index of `entries[0]` when they are a window of the queue.
    /// Previous at the first song restarts it. Next past the end wraps only under Repeat All
    /// when `entries` holds the whole queue; otherwise the destination is unknown.
    public static func destination(
        from currentID: String?,
        by offset: Int,
        in entries: [QueueEntry],
        firstIndex: Int = 0,
        repeatMode: String,
        complete: Bool
    ) -> (entry: QueueEntry, index: Int)? {
        guard let currentID, let index = entries.firstIndex(where: { $0.id == currentID }) else { return nil }
        var target = index + offset
        if target < 0 {
            guard firstIndex == 0 else { return nil }
            target = 0
        }
        if target >= entries.count {
            guard complete, repeatMode == "all", !entries.isEmpty else { return nil }
            target %= entries.count
        }
        return (entries[target], firstIndex + target)
    }
}

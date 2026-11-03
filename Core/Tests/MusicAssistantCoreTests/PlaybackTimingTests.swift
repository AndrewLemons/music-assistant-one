import Foundation
@testable import MusicAssistantCore
import Testing

private let receipt = Date(timeIntervalSince1970: 10000)

private func timedQueue(
    item: String = "first", position: Double = 80, skew: Double = 0,
    state: String = "playing", at date: Date = receipt
) -> PlayerQueue {
    PlayerQueue(.object([
        "queue_id": .string("linked-sendspin"), "state": .string(state), "active": .bool(true),
        "elapsed_time": .number(position),
        "elapsed_time_last_updated": .number(date.timeIntervalSince1970 + skew),
        "playback_speed": .number(1), "flow_mode": .bool(true),
        "current_item": .object([
            "queue_item_id": .string(item), "duration": .number(200),
            "media_item": .object(["uri": .string("library://track/repeated-song")]),
            "streamdetails": .object(["seek_position": .number(60)]),
        ]),
    ]), receivedAt: date)
}

@Test(arguments: [-5.0, 0, 5])
func queueClockIgnoresServerSkewAndFlowSeekOffsets(_ skew: Double) {
    let queue = timedQueue(position: 12, skew: skew)
    #expect(queue.elapsed(at: receipt) == 12)
    #expect(queue.elapsed(at: receipt.addingTimeInterval(0.5)) == 12.5)
    #expect(queue.elapsed(at: receipt.addingTimeInterval(2)) == 14)
    let paused = queue.predicting(["state": .string("paused")], at: receipt.addingTimeInterval(2))
    #expect(paused.elapsed(at: receipt.addingTimeInterval(20)) == 14)
    let playing = paused.predicting(["state": .string("playing")], at: receipt.addingTimeInterval(20))
    #expect(playing.elapsed(at: receipt.addingTimeInterval(21)) == 15)
}

@Test func identicalSnapshotDoesNotRestartPlaybackClock() {
    let queue = timedQueue()
    let updated = queue.receiving(queue.raw, at: receipt.addingTimeInterval(4))
    #expect(updated.elapsed(at: receipt.addingTimeInterval(5)) == 85)
    // Settings-only predictions must preserve the original receipt anchor too.
    #expect(updated.predicting(["shuffle_enabled": .bool(true)]).elapsed(at: receipt.addingTimeInterval(5)) == 85)
}

@Test func metadataChangeWithPreviousClockStartsAtZero() {
    let queue = timedQueue()
    let next = queue.receiving(queue.raw.merging([
        "current_item": timedQueue(item: "second").raw["current_item"],
    ]), at: receipt.addingTimeInterval(1))
    #expect(next.itemID == "second")
    #expect(next.elapsed(at: receipt.addingTimeInterval(1)) == 0)
    #expect(next.elapsed(at: receipt.addingTimeInterval(1.5)) == 0.5)
    let corrected = next.receivingTime(0.8, at: receipt.addingTimeInterval(1.8))
    #expect(abs(corrected.elapsed(at: receipt.addingTimeInterval(2)) - 1) < 0.000001)
}

@Test func numericTimeEventUsesLocalReceiptAndDoesNotAddFlowStreamOffset() throws {
    let queue = timedQueue()
    let updated = try #require(queue.applying(.object([
        "event": .string("queue_time_updated"), "object_id": .string(queue.id), "data": .number(10),
    ]), at: receipt.addingTimeInterval(1)))
    #expect(updated.elapsed(at: receipt.addingTimeInterval(1.5)) == 10.5)
    #expect(updated.applying(.object([
        "event": .string("queue_time_updated"), "object_id": .string("another-room"), "data": .number(99),
    ])) == nil)
}

@Test func displayClockResetsForOccurrencesRoomsAndRealBackwardSeeks() {
    let clock = PlaybackClock()
    let queue = timedQueue()
    #expect(clock.value(queue, at: receipt) == 80)
    let drift = queue.receiving(
        timedQueue(position: 79.5, at: receipt.addingTimeInterval(0.5)).raw,
        at: receipt.addingTimeInterval(0.5)
    )
    #expect(clock.value(drift, at: receipt.addingTimeInterval(0.5)) == 80)
    // Even a one-second backward seek must bypass drift smoothing.
    let seek = drift.receivingTime(79, at: receipt.addingTimeInterval(0.6))
    #expect(clock.value(seek, at: receipt.addingTimeInterval(0.6)) == 79)
    #expect(clock.value(timedQueue(item: "second", position: 0), at: receipt) == 0)
    #expect(clock.value(PlayerQueue(queue.raw.merging([
        "queue_id": .string("another-room"), "elapsed_time": .number(0),
    ]), receivedAt: receipt), at: receipt) == 0)
}

@MainActor @Test func seekDoesNotSurviveAutoAdvanceOfRepeatedSong() {
    let transport = TransportControl()
    defer { transport.cancel() }
    let queue = timedQueue(at: .now)
    transport.update(queue)
    transport.seek(120, target: .init(queueID: queue.id, playerID: "sendspin-protocol"))
    #expect(transport.displayed(queue)?.elapsed(at: .now) ?? 0 >= 120)
    let next = timedQueue(item: "second", position: 0, at: .now)
    transport.update(next)
    #expect(transport.predictions[queue.id]?.position == nil)
    #expect(transport.displayed(next)?.elapsed(at: next.receivedAt) == 0)
}

@MainActor @Test func startingOrSelectingSongDropsPreviousSeekImmediately() {
    for select in [true, false] {
        let transport = TransportControl()
        let queue = timedQueue(at: .now)
        let target = TransportControl.Target(queueID: queue.id, playerID: "sendspin-protocol")
        transport.update(queue)
        transport.seek(120, target: target)
        let entry = QueueEntry(timedQueue(item: "second").raw["current_item"])
        if select {
            transport.select(entry, index: 1, target: target)
        } else {
            transport.start(entry.media, target: target) {}
        }
        #expect(transport.predictions[queue.id]?.position == nil)
        #expect(transport.displayed(queue)?.elapsed(at: .now) ?? 200 < 0.1)
        transport.cancel()
    }
}

@MainActor @Test func seekHoldsPastOldThreeSecondUIReleaseAndConfirms() async throws {
    let transport = TransportControl()
    defer { transport.cancel() }
    let queue = timedQueue(at: .now)
    let issued = Date.now
    transport.update(queue)
    transport.seek(120, target: .init(queueID: queue.id, playerID: "sendspin-protocol"))
    // Let the command writer acknowledge, then model a slow stream rebuild deterministically.
    for _ in 0 ..< 20 where transport.predictions[queue.id]?.position?.acknowledged == nil {
        await Task.yield()
    }
    var prediction = try #require(transport.predictions[queue.id])
    #expect(prediction.position?.acknowledged != nil)
    prediction.reconcile(with: queue, at: issued.addingTimeInterval(4))
    #expect(prediction.position != nil)
    #expect(prediction.applied(to: queue).elapsed(at: issued.addingTimeInterval(4)) == 120)
    let truth = timedQueue(position: 120, at: issued.addingTimeInterval(4))
    prediction.reconcile(with: truth, at: issued.addingTimeInterval(4))
    #expect(prediction.position == nil)
}

@Test func seekResolutionRejectsInactiveAndMissingQueues() {
    let target = TransportControl.Target(queueID: "protocol", playerID: "protocol")
    #expect(throws: MAError.self) { try target.resolvingActiveQueue(.null) }
    #expect(throws: MAError.self) {
        try target.resolvingActiveQueue(.object(["queue_id": .string("wrapper"), "active": .bool(false)]))
    }
}

@Test func seekResolutionRejectsTrackChangeDuringActiveQueueLookup() throws {
    let queue = timedQueue()
    let target = TransportControl.Target(queueID: queue.id, playerID: "protocol")
    #expect(throws: MAError.self) {
        try target.resolvingActiveQueue(timedQueue(item: "second").raw, expectedItemID: queue.itemID)
    }
    #expect(try target.resolvingActiveQueue(queue.raw, expectedItemID: queue.itemID).queueID == queue.id)
}

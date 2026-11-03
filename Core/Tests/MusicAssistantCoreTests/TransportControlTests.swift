import Foundation
@testable import MusicAssistantCore
import Testing

private let start = Date(timeIntervalSince1970: 1_000_000)

private func entry(_ id: String) -> QueueEntry {
    QueueEntry(.object([
        "queue_item_id": .string(id), "duration": .number(200),
        "media_item": .object(["uri": .string("library://track/\(id)"), "name": .string(id)]),
    ]))
}

private let entries = ["a", "b", "c", "d"].map(entry)

private func queue(
    current: String = "a",
    playing: Bool = true,
    elapsed: Double = 30,
    at date: Date = start,
    shuffle: Bool = false,
    repeatMode: String = "off"
) -> PlayerQueue {
    PlayerQueue(.object([
        "queue_id": .string("room"), "state": .string(playing ? "playing" : "paused"),
        "elapsed_time": .number(elapsed), "elapsed_time_last_updated": .number(date.timeIntervalSince1970),
        "current_item": entry(current).raw, "shuffle_enabled": .bool(shuffle), "repeat_mode": .string(repeatMode),
    ]), receivedAt: date)
}

private func currentID(_ queue: PlayerQueue?) -> String? {
    queue?.raw["current_item"]["queue_item_id"].string
}

// MARK: - Prediction

@Test func pauseFreezesTheClockAtTheTapAndPlayResumesFromIt() {
    var prediction = TransportPrediction()
    prediction.playing = .init(false, issued: start.addingTimeInterval(5), sequence: 1)
    let paused = prediction.applied(to: queue())
    #expect(!paused.isPlaying)
    #expect(paused.elapsed(at: start.addingTimeInterval(60)) == 35)
    prediction.playing = .init(true, issued: start.addingTimeInterval(20), sequence: 2)
    let resumed = prediction.applied(to: queue(playing: false, elapsed: 35))
    #expect(resumed.isPlaying)
    #expect(resumed.elapsed(at: start.addingTimeInterval(22)) == 37)
}

@Test func skipShowsTheDestinationFromZeroAndKeepsSeekOrder() {
    var prediction = TransportPrediction()
    prediction.item = .init(.init(entry: entries[1], index: 1), issued: start.addingTimeInterval(1), sequence: 1)
    var shown = prediction.applied(to: queue())
    #expect(currentID(shown) == "b")
    #expect(shown.raw["current_index"].double == 1)
    #expect(shown.current?.name == "b")
    #expect(shown.elapsed(at: start.addingTimeInterval(3)) == 0, "Wait for the new song's clock before advancing")
    // A seek after the skip applies to the new song.
    prediction.position = .init(90, issued: start.addingTimeInterval(4), sequence: 2)
    shown = prediction.applied(to: queue())
    #expect(shown.elapsed(at: start.addingTimeInterval(4)) == 90)
    // A seek issued before a skip is superseded by it.
    prediction.position = .init(90, issued: start, sequence: 0)
    #expect(prediction.applied(to: queue()).elapsed(at: start.addingTimeInterval(1)) == 0)
}

@Test func skipDestinationsFollowQueueOrder() {
    func destination(_ current: String, _ offset: Int, repeatMode: String = "off", complete: Bool = true) -> String? {
        TransportPrediction.destination(
            from: current, by: offset, in: entries, repeatMode: repeatMode, complete: complete
        )?.entry.id
    }
    #expect(destination("a", 1) == "b")
    #expect(destination("a", 3) == "d")
    #expect(destination("b", -1) == "a")
    #expect(destination("a", -1) == "a", "Previous on the first song restarts it")
    #expect(destination("d", 1) == nil, "The end of the queue is the server's decision")
    #expect(destination("d", 1, repeatMode: "all") == "a")
    #expect(destination("d", 1, repeatMode: "all", complete: false) == nil)
    #expect(destination("z", 1) == nil)
    let window = TransportPrediction.destination(
        from: "b", by: -1, in: Array(entries[1...]), firstIndex: 1, repeatMode: "off", complete: false
    )
    #expect(window == nil, "A window can't see the song before its first entry")
    #expect(TransportPrediction.destination(
        from: "b", by: 2, in: Array(entries[1...]), firstIndex: 1, repeatMode: "off", complete: false
    )?.index == 3)
}

@Test func staleSnapshotsNeverClearAnUnacknowledgedPrediction() {
    var prediction = TransportPrediction()
    prediction.item = .init(.init(entry: entries[2], index: 2), issued: start, sequence: 1)
    prediction.playing = .init(false, issued: start, sequence: 1)
    prediction.reconcile(with: queue(current: "a"), at: start.addingTimeInterval(1))
    #expect(prediction.item != nil)
    #expect(prediction.playing != nil)
    // Even a matching snapshot can be an older state until the command is acknowledged.
    prediction.reconcile(with: queue(current: "c", playing: false), at: start.addingTimeInterval(1))
    #expect(prediction.item != nil)
}

@Test func acknowledgedPredictionsClearWhenConfirmedOrSuperseded() {
    var prediction = TransportPrediction()
    prediction.item = .init(.init(entry: entries[2], index: 2), issued: start, sequence: 1, grace: 2)
    prediction.shuffle = .init(true, issued: start, sequence: 2, grace: 2)
    prediction.acknowledge(1, at: start.addingTimeInterval(1))
    prediction.acknowledge(2, at: start.addingTimeInterval(1))
    // Within the grace period, a different state is treated as stale.
    prediction.reconcile(with: queue(current: "b"), at: start.addingTimeInterval(2))
    #expect(prediction.item != nil)
    #expect(prediction.shuffle != nil)
    // A matching snapshot settles its field only.
    prediction.reconcile(with: queue(current: "c"), at: start.addingTimeInterval(2))
    #expect(prediction.item == nil)
    #expect(prediction.shuffle != nil)
    // After the grace period, the server's state supersedes the prediction.
    prediction.reconcile(with: queue(current: "c"), at: start.addingTimeInterval(3))
    #expect(prediction.isEmpty)
}

@Test func onlyTheLatestCommandAcknowledgesAField() {
    var prediction = TransportPrediction()
    prediction.playing = .init(true, issued: start, sequence: 2)
    prediction.acknowledge(1, at: start)
    prediction.reconcile(with: queue(playing: true), at: start.addingTimeInterval(1))
    #expect(prediction.playing != nil, "An older command's acknowledgement can't confirm a newer request")
    prediction.acknowledge(2, at: start.addingTimeInterval(1))
    prediction.reconcile(with: queue(playing: true), at: start.addingTimeInterval(1))
    #expect(prediction.playing == nil)
}

@Test func unacknowledgedPredictionsExpire() {
    var prediction = TransportPrediction()
    prediction.repeatMode = .init("one", issued: start, sequence: 1, timeout: 5)
    #expect(prediction.deadline == start.addingTimeInterval(5))
    prediction.reconcile(with: nil, at: start.addingTimeInterval(4))
    #expect(prediction.repeatMode != nil)
    prediction.reconcile(with: nil, at: start.addingTimeInterval(5))
    #expect(prediction.isEmpty)
}

@Test func seekSettlesWhenTheServerReachesTheTarget() {
    var prediction = TransportPrediction()
    prediction.position = .init(120, issued: start, sequence: 1)
    prediction.acknowledge(1, at: start)
    prediction.reconcile(with: queue(elapsed: 30), at: start.addingTimeInterval(1))
    #expect(prediction.position != nil, "The old position mustn't snap the scrubber back")
    prediction.reconcile(
        with: queue(elapsed: 120.5, at: start.addingTimeInterval(1)), at: start.addingTimeInterval(1)
    )
    #expect(prediction.position == nil)
}

@Test func startingASongMatchesByURI() {
    var prediction = TransportPrediction()
    let song = entries[3].media
    prediction.item = .init(.init(media: song), issued: start, sequence: 1)
    let shown = prediction.applied(to: queue())
    #expect(shown.current?.uri == song.uri)
    #expect(shown.duration == 0 || shown.duration == song.duration)
    prediction.acknowledge(1, at: start)
    prediction.reconcile(with: queue(current: "d"), at: start.addingTimeInterval(1))
    #expect(prediction.item == nil)
}

// MARK: - Coordinator

@MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate(), "Timed out waiting for transport work")
}

/// Holds each command until the test releases it, like a slow speaker.
@MainActor private final class Server {
    var sent: [TransportControl.Command] = []
    var failures: Set<Int> = []
    private var gates: [CheckedContinuation<Void, Never>] = []

    func send(_ command: TransportControl.Command) async throws {
        sent.append(command)
        let index = sent.count - 1
        await withCheckedContinuation { gates.append($0) }
        if failures.contains(index) {
            throw MAError.message("Speaker unavailable")
        }
    }

    var waiting: Int {
        gates.count
    }

    func release() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
}

private let target = TransportControl.Target(queueID: "room", playerID: "room")

@MainActor private func control(_ server: Server) -> TransportControl {
    let control = TransportControl()
    control.send = { _, command in try await server.send(command) }
    control.onError = { _ in Issue.record("Unexpected error") }
    return control
}

@MainActor @Test func rapidNextTapsShowTheFinalSongAndCoalesce() async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(current: "a"))
    transport.skip(1, target: target, entries: entries, complete: true)
    #expect(currentID(transport.displayed(queue(current: "a"))) == "b")
    try await waitUntil { server.waiting == 1 }
    transport.skip(1, target: target, entries: entries, complete: true)
    transport.skip(1, target: target, entries: entries, complete: true)
    #expect(currentID(transport.displayed(queue(current: "a"))) == "d", "Every tap shows immediately")
    // An older snapshot from before the first skip must not move the display back.
    transport.update(queue(current: "a"))
    #expect(currentID(transport.displayed(queue(current: "a"))) == "d")
    server.release()
    try await waitUntil { server.waiting == 1 }
    #expect(server.sent == [.next, .select(entryID: "d")], "Queued taps become one jump")
    transport.update(queue(current: "b"))
    #expect(currentID(transport.displayed(queue(current: "b"))) == "d", "An intermediate song isn't the result")
    server.release()
    try await waitUntil { server.waiting == 0 }
    transport.update(queue(current: "d", elapsed: 0, at: .now))
    try await waitUntil { transport.predictions.isEmpty }
}

@MainActor @Test func playPauseIsLatestWins() async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(playing: false))
    transport.setPlaying(true, target: target)
    #expect(transport.displayed(queue(playing: false))?.isPlaying == true)
    try await waitUntil { server.waiting == 1 }
    transport.setPlaying(false, target: target)
    transport.setPlaying(true, target: target)
    #expect(transport.displayed(queue(playing: false))?.isPlaying == true)
    server.release()
    try await waitUntil { server.waiting == 0 && server.sent.count == 1 }
    // Play, pause, play while the first play was in flight sends one play.
    try await Task.sleep(for: .milliseconds(30))
    #expect(server.sent == [.play])
    transport.setPlaying(false, target: target)
    try await waitUntil { server.waiting == 1 }
    #expect(server.sent == [.play, .pause])
    server.release()
}

@MainActor @Test func oppositeQueuedSkipsCancel() async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(current: "b"))
    transport.setShuffle(true, target: target)
    try await waitUntil { server.waiting == 1 }
    transport.skip(1, target: target, entries: entries)
    transport.skip(-1, target: target, entries: entries)
    #expect(currentID(transport.displayed(queue(current: "b"))) == "b")
    server.release()
    try await waitUntil { server.waiting == 0 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(server.sent == [.shuffle(true)])
}

@MainActor @Test func seeksKeepTheLatestTargetUntilConfirmed() async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(elapsed: 10, at: .now))
    transport.setRepeat("all", target: target)
    try await waitUntil { server.waiting == 1 }
    transport.seek(50, target: target)
    transport.seek(80, target: target)
    let shown = try #require(transport.displayed(queue(elapsed: 10, at: .now)))
    #expect(abs(shown.elapsed() - 80) < 1)
    server.release()
    try await waitUntil { server.waiting == 1 }
    server.release()
    try await waitUntil { transport.predictions["room"]?.position?.acknowledged != nil }
    #expect(server.sent == [.repeatMode("all"), .seek(80)])
    // The pre-seek position is still reported: keep the target.
    transport.update(queue(elapsed: 12, at: .now))
    #expect(transport.predictions["room"]?.position != nil)
    transport.update(queue(elapsed: 80, at: .now, repeatMode: "all"))
    #expect(transport.predictions["room"] == nil)
}

@MainActor @Test func failedCommandsRevertAndReport() async throws {
    let server = Server()
    server.failures = [0]
    var errors = 0
    let transport = control(server)
    transport.onError = { _ in errors += 1 }
    transport.update(queue(current: "a"))
    transport.skip(1, target: target, entries: entries)
    try await waitUntil { server.waiting == 1 }
    transport.skip(1, target: target, entries: entries)
    #expect(currentID(transport.displayed(queue(current: "a"))) == "c")
    server.release()
    try await waitUntil { transport.predictions.isEmpty }
    #expect(currentID(transport.displayed(queue(current: "a"))) == "a")
    #expect(errors == 1)
    #expect(server.sent == [.next], "Queued work behind a failure is dropped")
}

@MainActor @Test func unconfirmedStateRevertsAfterGrace() async throws {
    let server = Server()
    let transport = control(server)
    transport.grace = 0.2
    transport.pollInterval = .milliseconds(20)
    var refreshes = 0
    transport.refresh = { _ in refreshes += 1 }
    transport.update(queue(playing: true))
    transport.setPlaying(false, target: target)
    try await waitUntil { server.waiting == 1 }
    server.release()
    try await waitUntil { refreshes > 0 }
    #expect(transport.displayed(queue(playing: true))?.isPlaying == false)
    // The speaker never paused: show its real state.
    try await waitUntil { transport.predictions.isEmpty }
    #expect(transport.displayed(queue(playing: true))?.isPlaying == true)
}

@MainActor @Test func aStartShowsTheChosenSongAndANewerStartReplacesAQueuedOne() async throws {
    let server = Server()
    let transport = control(server)
    var started: [String] = []
    transport.update(queue(current: "a", playing: false))
    transport.setRepeat("one", target: target)
    try await waitUntil { server.waiting == 1 }
    transport.start(entries[2].media, target: target) { started.append("c") }
    transport.start(entries[3].media, target: target) { started.append("d") }
    let shown = transport.displayed(queue(current: "a", playing: false))
    #expect(shown?.current?.name == "d")
    #expect(shown?.isPlaying == true)
    server.release()
    try await waitUntil { started == ["d"] }
    transport.cancel()
    #expect(transport.predictions.isEmpty)
}

@MainActor @Test func queuedSeekIsDroppedWhenTheServerAdvancesBeforeItIsSent() async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(at: .now))
    transport.setShuffle(true, target: target)
    try await waitUntil { server.waiting == 1 }
    transport.seek(100, target: target)
    transport.update(queue(current: "b", elapsed: 0, at: .now))
    server.release()
    for _ in 0 ..< 20 {
        await Task.yield()
    }
    #expect(server.sent == [.shuffle(true)], "A drag on the previous song must not seek the new song")
    transport.cancel()
}

@MainActor @Test func previousAfterFiveSecondsRestartsTheSongLikeTheServer() async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(current: "b", elapsed: 30, at: .now))
    transport.skip(-1, target: target, entries: entries, complete: true)
    let shown = transport.displayed(queue(current: "b", elapsed: 30, at: .now))
    #expect(currentID(shown) == "b", "The current song restarts")
    #expect((shown?.elapsed() ?? 99) < 1)
    try await waitUntil { server.waiting == 1 }
    #expect(server.sent == [.previous])
    // Music Assistant resets elapsed on restart, so another Previous goes back a song.
    transport.skip(-1, target: target, entries: entries, complete: true)
    #expect(currentID(transport.displayed(queue(current: "b", elapsed: 30, at: .now))) == "a")
    server.release()
    try await waitUntil { server.waiting == 1 }
    #expect(server.sent == [.previous, .previous])
    server.release()
}

@MainActor @Test func previousEarlyInASongGoesBack() {
    let server = Server()
    let transport = control(server)
    transport.update(queue(current: "b", elapsed: 2, at: .now))
    transport.skip(-1, target: target, entries: entries, complete: true)
    #expect(currentID(transport.displayed(queue(current: "b", elapsed: 2, at: .now))) == "a")
}

@MainActor @Test func additiveQueueOperationsAreRetainedInOrder() async throws {
    let server = Server()
    let transport = control(server)
    var added: [String] = []
    transport.setRepeat("one", target: target)
    try await waitUntil { server.waiting == 1 }
    transport.start(nil, target: target, replacing: false) { added.append("b") }
    transport.start(nil, target: target, replacing: false) { added.append("c") }
    server.release()
    try await waitUntil { added.last == "c" }
    #expect(added == ["b", "c"])
    transport.cancel()
}

@MainActor @Test(arguments: ["select", "next", "previous", "stop", "start"])
func playStateIsInvalidatedByPlaybackChangingOperations(_ action: String) async throws {
    let server = Server()
    let transport = control(server)
    transport.update(queue(current: "a", elapsed: 1))
    transport.setPlaying(false, target: target)
    try await waitUntil { server.waiting == 1 }
    switch action {
    case "select": transport.select(entries[1], index: 1, target: target)
    case "next": transport.skip(1, target: target, entries: entries)
    case "previous": transport.skip(-1, target: target, entries: entries)
    case "stop": transport.stop(target: target)
    default: transport.start(nil, target: target) { try await server.send(.play) }
    }
    server.release()
    try await waitUntil { server.waiting == 1 }
    transport.setPlaying(false, target: target)
    server.release()
    try await waitUntil { server.sent.count == 3 || transport.predictions.isEmpty }
    #expect(server.sent.count == 3)
    #expect(server.sent.last == .pause)
    server.release()
    transport.cancel()
}

import Foundation
@testable import MusicAssistantCore
import Testing

private func localQueue(_ state: String = "playing", item: String = "entry") -> PlayerQueue {
    PlayerQueue(.object([
        "queue_id": .string("local-queue"), "state": .string(state),
        "current_item": .object(["queue_item_id": .string(item), "uri": .string("track://1")]),
    ]))
}

@MainActor @Test func interruptionWaitsForPauseAndResumesCapturedLocalPlayer() async throws {
    let state = PlaybackInterruption()
    let target = try #require(InterruptedPlayback(playerID: "local", queue: localQueue()))
    var actions: [String] = []
    state.begin(target) {
        try await Task.sleep(for: .milliseconds(25))
        actions.append("pause")
    }
    try await state.end(shouldResume: true) { resumed in
        #expect(resumed.playerID == "local")
        #expect(state.isResuming)
        actions.append("resume")
    }
    #expect(actions == ["pause", "resume"])
    #expect(!state.isInterrupted && !state.isResuming)
    try await state.end(shouldResume: true) { _ in Issue.record("Duplicate end resumed playback") }
}

@MainActor @Test(arguments: [false, true])
func interruptionDoesNotResumeAfterUserPauseOrSystemDenial(cancel: Bool) async throws {
    let state = PlaybackInterruption()
    let target = try #require(InterruptedPlayback(playerID: "local", queue: localQueue()))
    state.begin(target) {}
    if cancel {
        state.cancelResume()
    }
    try await state.end(shouldResume: cancel) { _ in Issue.record("Unexpected automatic resume") }
    #expect(!state.isInterrupted)
}

@MainActor @Test func interruptionNeverResumesInitiallyPausedOrFailedPause() async throws {
    #expect(InterruptedPlayback(playerID: "local", queue: localQueue("paused")) == nil)
    let state = PlaybackInterruption()
    state.begin(nil) {}
    try await state.end(shouldResume: true) { _ in Issue.record("Resumed idle audio") }
    state.begin(InterruptedPlayback(playerID: "local", queue: localQueue())) { throw URLError(.networkConnectionLost) }
    try await state.end(shouldResume: true) { _ in Issue.record("Resumed after failed pause") }
}

@Test func interruptionRejectsChangedQueueEntryOrPlayer() throws {
    let target = try #require(InterruptedPlayback(playerID: "local", queue: localQueue()))
    #expect(target.matches(playerID: "local", queue: localQueue("paused")))
    #expect(!target.matches(playerID: "other-room", queue: localQueue("paused")))
    #expect(!target.matches(playerID: "local", queue: localQueue("paused", item: "next-entry")))
}

@MainActor @Test func duplicateInterruptionEndsDoNotSendDuplicateResume() async throws {
    let state = PlaybackInterruption()
    state.begin(InterruptedPlayback(playerID: "local", queue: localQueue())) {
        try await Task.sleep(for: .milliseconds(30))
    }
    var resumes = 0
    let first = Task { try await state.end(shouldResume: true) { _ in resumes += 1 } }
    let second = Task { try await state.end(shouldResume: true) { _ in resumes += 1 } }
    try await first.value
    try await second.value
    #expect(resumes == 1)
}

@MainActor @Test func stopInvalidatesAnInterruptionWhilePauseIsInFlight() async throws {
    let state = PlaybackInterruption()
    state.begin(InterruptedPlayback(playerID: "local", queue: localQueue())) {
        try await Task.sleep(for: .seconds(1))
    }
    let ending = Task { try await state.end(shouldResume: true) { _ in Issue.record("Resumed after stop") } }
    state.reset()
    try await ending.value
    #expect(state.playback == nil && !state.isInterrupted)
}

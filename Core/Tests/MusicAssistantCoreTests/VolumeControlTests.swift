import Foundation
@testable import MusicAssistantCore
import Testing

@MainActor @Test func volumeWritesAreOrderedAndKeepLatestAdjustment() async throws {
    let control = VolumeControl()
    var writes: [Double] = []
    var release: CheckedContinuation<Void, Never>?
    let send: @MainActor (Double) async throws -> Void = { value in
        writes.append(value)
        if writes.count == 1 {
            await withCheckedContinuation { release = $0 }
        }
    }
    control.set(10, playerID: "room", send: send, onError: { _ in Issue.record("Unexpected error") })
    try await Task.sleep(for: .milliseconds(180))
    #expect(writes == [10])
    control.set(20, playerID: "room", send: send, onError: { _ in })
    control.set(30, playerID: "room", send: send, onError: { _ in })
    #expect(control.pending["room"] == 30)
    release?.resume()
    try await Task.sleep(for: .milliseconds(30))
    #expect(writes == [10, 30])
    #expect(control.pending.isEmpty)
}

@MainActor @Test func volumeFailureRollsBackAndAllowsRetry() async throws {
    let control = VolumeControl()
    var errors = 0
    control.set(
        40,
        playerID: "room",
        send: { _ in throw URLError(.notConnectedToInternet) },
        onError: { _ in errors += 1 }
    )
    try await Task.sleep(for: .milliseconds(180))
    #expect(errors == 1)
    #expect(control.pending.isEmpty)
    var written: Double?
    control.set(200, playerID: "room", send: { written = $0 }, onError: { _ in })
    try await Task.sleep(for: .milliseconds(180))
    #expect(written == 100)
}

@MainActor @Test func cancelPreventsQueuedVolumeWrites() async throws {
    let control = VolumeControl()
    var writes = 0
    control.set(40, playerID: "room", send: { _ in writes += 1 }, onError: { _ in })
    control.cancel()
    control.set(.nan, playerID: "room", send: { _ in writes += 1 }, onError: { _ in })
    try await Task.sleep(for: .milliseconds(180))
    #expect(writes == 0)
    #expect(control.pending.isEmpty)
}

@Test func localPlayerIdentityIncludesServerWrapper() {
    let wrapper = Player(.object([
        "player_id": .string("wrapper"),
        "output_protocols": .array([.object(["output_protocol_id": .string("sendspin-id")])]),
    ]))
    #expect(wrapper.represents(localPlayerID: "sendspin-id"))
    #expect(!wrapper.represents(localPlayerID: nil))
    #expect(!wrapper.represents(localPlayerID: "another-device"))
}

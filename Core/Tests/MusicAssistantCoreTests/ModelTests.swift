import Foundation
import Testing
@testable import MusicAssistantCore

@Test func addressesPreserveProxyPathsAndPreferTLS() throws {
    let server = try ServerAddress(" music.example.com/music/ ")
    #expect(server.baseURL.absoluteString == "https://music.example.com/music")
    #expect(server.endpoint("ws", websocket: true).absoluteString == "wss://music.example.com/music/ws")
    #expect(try ServerAddress("10.0.0.11:8095").baseURL.scheme == "http")
    #expect(try ServerAddress("http://[::1]:8095/").endpoint("api").absoluteString == "http://[::1]:8095/api")
}

@Test(arguments: ["ftp://example.com", "https://user:password@example.com", "https://example.com?token=secret", "", "not a host"])
func invalidAddressesAreRejected(_ address: String) {
    #expect(throws: (any Error).self) { try ServerAddress(address) }
}

@Test func queueProgressInterpolatesOnlyWhilePlayingAndClamps() {
    let now = Date(timeIntervalSince1970: 100)
    let playing = PlayerQueue(.object(["state": .string("playing"), "elapsed_time": .number(30), "elapsed_time_last_updated": .number(90), "current_item": .object(["duration": .number(35)])]))
    #expect(playing.elapsed(at: now) == 35)
    let paused = PlayerQueue(.object(["state": .string("paused"), "elapsed_time": .number(30), "elapsed_time_last_updated": .number(90)]))
    #expect(paused.elapsed(at: now) == 30)
    #expect(playing.elapsed(at: Date(timeIntervalSince1970: 80)) == 30)
}

@Test func groupingRequiresServerAdvertisedCompatibility() {
    let player = Player(.object(["player_id": .string("one"), "available": .bool(true), "can_group_with": .array([.string("sendspin")])]))
    let compatible = Player(.object(["player_id": .string("two"), "available": .bool(true), "provider": .string("sendspin")]))
    let incompatible = Player(.object(["player_id": .string("three"), "available": .bool(true), "provider": .string("sonos")]))
    #expect(player.canJoin(compatible))
    #expect(!player.canJoin(incompatible))
    #expect(!player.canJoin(player))
    #expect(!Player(.object(["available": .bool(false)])).canJoin(compatible))
}

@Test func artworkUsesOpaqueProxyIdentifier() throws {
    let item = MediaItem(.object(["uri": .string("library://track/1"), "metadata": .object(["images": .array([.object(["type": .string("thumb"), "proxy_id": .string("abc123"), "path": .string("/private/file.jpg")])])])]))
    #expect(item.artworkURL(server: try ServerAddress("https://example.com"))?.absoluteString == "https://example.com/imageproxy/abc123")
    #expect(item.artworkURL(server: nil) == nil)
}

@Test func unknownJSONFieldsAndNullsSurviveRoundTrip() throws {
    let data = Data(#"{"result":[{"future_field":true,"volume_level":null}],"partial":false}"#.utf8)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(value["result"].array.first?["future_field"].bool == true)
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}

@Test(arguments: ["paused", "idle"])
func pausedQueueUsesServerResumePositionWhenPlayerClockResets(_ state: String) {
    let queue = PlayerQueue(.object([
        "state": .string(state), "elapsed_time": .number(0), "resume_pos": .number(67),
        "elapsed_time_last_updated": .number(90),
        "current_item": .object(["duration": .number(243)])
    ]))
    #expect(queue.elapsed(at: Date(timeIntervalSince1970: 100)) == 67)
    #expect(queue.elapsed(at: Date(timeIntervalSince1970: 500)) == 67)
}

@Test func resumePositionDoesNotOverridePlaybackOrAuthoritativePausedPosition() {
    func queue(state: String, elapsed: Double, resume: Double, ended: Bool = false) -> PlayerQueue {
        PlayerQueue(.object([
            "state": .string(state), "elapsed_time": .number(elapsed), "resume_pos": .number(resume),
            "elapsed_time_last_updated": .number(100), "ended": .bool(ended),
            "current_item": .object(["duration": .number(243)])
        ]))
    }
    let now = Date(timeIntervalSince1970: 100)
    #expect(queue(state: "playing", elapsed: 0, resume: 67).elapsed(at: now) == 0)
    #expect(queue(state: "paused", elapsed: 20, resume: 67).elapsed(at: now) == 20)
    #expect(queue(state: "paused", elapsed: 0, resume: 0).elapsed(at: now) == 0)
    #expect(queue(state: "idle", elapsed: 0, resume: 67, ended: true).elapsed(at: now) == 0)
    #expect(queue(state: "paused", elapsed: 0, resume: 999).elapsed(at: now) == 243)
    #expect(queue(state: "paused", elapsed: 0, resume: -5).elapsed(at: now) == 0)
    #expect(PlayerQueue(.object(["state": .string("idle"), "resume_pos": .number(67)])).elapsed(at: now) == 0)
}

@Test func predictedPauseFreezesInterpolatedPositionAndResumeContinuesIt() {
    let queue = PlayerQueue(.object([
        "queue_id": .string("room"), "state": .string("playing"),
        "elapsed_time": .number(20), "elapsed_time_last_updated": .number(100),
        "current_item": .object(["duration": .number(200)])
    ]))
    let paused = queue.predicting(["state": .string("paused")], at: Date(timeIntervalSince1970: 110))
    #expect(!paused.isPlaying)
    #expect(paused.elapsed(at: Date(timeIntervalSince1970: 150)) == 30)
    let resumed = paused.predicting(["state": .string("playing")], at: Date(timeIntervalSince1970: 150))
    #expect(resumed.elapsed(at: Date(timeIntervalSince1970: 155)) == 35)
    #expect(queue.isPlaying)
    #expect(paused.current == queue.current)
}

@Test func predictedSeekToZeroClearsResumePosition() {
    let queue = PlayerQueue(.object([
        "state": .string("paused"), "elapsed_time": .number(0), "resume_pos": .number(67),
        "current_item": .object(["duration": .number(200)])
    ]))
    #expect(queue.predicting(["elapsed_time": .number(0)]).elapsed() == 0)
    let modes = queue.predicting(["shuffle_enabled": .bool(true), "repeat_mode": .string("one")])
    #expect(modes.shuffle)
    #expect(modes.repeatMode == "one")
    #expect(modes.elapsed() == 67)
}

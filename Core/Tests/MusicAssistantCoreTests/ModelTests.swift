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

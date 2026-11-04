import Foundation
@testable import MusicAssistantCore
import Testing

@Test func addressesPreserveProxyPathsAndPreferTLS() throws {
    let server = try ServerAddress(" music.example.com/music/ ")
    #expect(server.baseURL.absoluteString == "https://music.example.com/music")
    #expect(server.endpoint("ws", websocket: true).absoluteString == "wss://music.example.com/music/ws")
    #expect(try ServerAddress("music.example.com:8095").baseURL.scheme == "https")
    #expect(try ServerAddress("music.local:8095").baseURL.scheme == "http")
    #expect(try ServerAddress("[::1]:8095").baseURL.scheme == "http")
    #expect(try ServerAddress("10.0.0.11:8095").baseURL.scheme == "http")
    #expect(try ServerAddress("http://[::1]:8095/").endpoint("api").absoluteString == "http://[::1]:8095/api")
}

@Test(arguments: [
    "ftp://example.com",
    "https://user:password@example.com",
    "https://example.com?token=secret",
    "",
    "not a host",
])
func invalidAddressesAreRejected(_ address: String) {
    #expect(throws: (any Error).self) { try ServerAddress(address) }
}

@Test func queueProgressInterpolatesOnlyWhilePlayingAndClamps() {
    let now = Date(timeIntervalSince1970: 100)
    let playing = PlayerQueue(.object([
        "state": .string("playing"),
        "elapsed_time": .number(30),
        "elapsed_time_last_updated": .number(90),
        "current_item": .object(["duration": .number(35)]),
    ]), receivedAt: Date(timeIntervalSince1970: 90))
    #expect(playing.elapsed(at: now) == 35)
    let paused = PlayerQueue(.object([
        "state": .string("paused"),
        "elapsed_time": .number(30),
        "elapsed_time_last_updated": .number(90),
    ]))
    #expect(paused.elapsed(at: now) == 30)
    #expect(playing.elapsed(at: Date(timeIntervalSince1970: 80)) == 30)
}

@Test func groupingRequiresServerAdvertisedCompatibility() {
    let player = Player(.object([
        "player_id": .string("one"),
        "available": .bool(true),
        "can_group_with": .array([.string("sendspin")]),
    ]))
    let compatible = Player(.object([
        "player_id": .string("two"),
        "available": .bool(true),
        "provider": .string("sendspin"),
        "supported_features": .array([.string("set_members")]),
    ]))
    let incompatible = Player(.object([
        "player_id": .string("three"),
        "available": .bool(true),
        "provider": .string("sonos"),
    ]))
    #expect(player.canJoin(compatible))
    #expect(!player.canJoin(incompatible))
    #expect(!player.canJoin(player))
    #expect(!Player(.object(["available": .bool(false)])).canJoin(compatible))
}

@Test func artworkUsesOpaqueProxyIdentifier() throws {
    let item = MediaItem(.object([
        "uri": .string("library://track/1"),
        "metadata": .object(["images": .array([.object([
            "type": .string("thumb"),
            "proxy_id": .string("abc123"),
            "path": .string("/private/file.jpg"),
        ])])]),
    ]))
    #expect(try item.artworkURL(server: ServerAddress("https://example.com"))?
        .absoluteString == "https://example.com/imageproxy/abc123")
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
        "current_item": .object(["duration": .number(243)]),
    ]))
    #expect(queue.elapsed(at: Date(timeIntervalSince1970: 100)) == 67)
    #expect(queue.elapsed(at: Date(timeIntervalSince1970: 500)) == 67)
}

@Test func resumePositionDoesNotOverridePlaybackOrAuthoritativePausedPosition() {
    func queue(state: String, elapsed: Double, resume: Double, ended: Bool = false) -> PlayerQueue {
        PlayerQueue(.object([
            "state": .string(state), "elapsed_time": .number(elapsed), "resume_pos": .number(resume),
            "elapsed_time_last_updated": .number(100), "ended": .bool(ended),
            "current_item": .object(["duration": .number(243)]),
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
        "current_item": .object(["duration": .number(200)]),
    ]))
    let paused = PlayerQueue(queue.raw, receivedAt: Date(timeIntervalSince1970: 100)).predicting(
        ["state": .string("paused")],
        at: Date(timeIntervalSince1970: 110)
    )
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
        "current_item": .object(["duration": .number(200)]),
    ]))
    #expect(queue.predicting(["elapsed_time": .number(0)]).elapsed() == 0)
    let modes = queue.predicting(["shuffle_enabled": .bool(true), "repeat_mode": .string("one")])
    #expect(modes.shuffle)
    #expect(modes.repeatMode == "one")
    #expect(modes.elapsed() == 67)
}

@Test func playbackPickerIncludesUnhiddenAppPlayersAndOwnHiddenPlayer() {
    func player(_ fields: [String: JSONValue]) -> Player {
        Player(.object(["player_id": .string("phone"), "enabled": .bool(true), "private": .bool(true)]).merging(fields))
    }
    let hidden = player(["hide_in_ui": .bool(true)])
    #expect(!hidden.isVisiblePlaybackTarget(localPlayerID: "mac"))
    #expect(!hidden.isVisiblePlaybackTarget(localPlayerID: nil))
    #expect(hidden.isVisiblePlaybackTarget(localPlayerID: "phone"))
    #expect(player(["hide_in_ui": .bool(false)]).isVisiblePlaybackTarget(localPlayerID: "mac"))
    #expect(!player(["enabled": .bool(false)]).isVisiblePlaybackTarget(localPlayerID: "phone"))
    #expect(player(["available": .bool(false)]).isVisiblePlaybackTarget(localPlayerID: nil))
}

@Test func playbackPickerRecognizesLocalOutputWithoutShowingProtocolOrInputDevices() {
    let wrapper = Player(.object([
        "player_id": .string("wrapper"), "hide_in_ui": .bool(true),
        "output_protocols": .array([.object(["output_protocol_id": .string("local")])]),
    ]))
    #expect(wrapper.isVisiblePlaybackTarget(localPlayerID: "local"))
    #expect(!wrapper.isVisiblePlaybackTarget(localPlayerID: "other"))
    for type in ["protocol", "source"] {
        let player = Player(.object(["player_id": .string("local"), "type": .string(type)]))
        #expect(!player.isVisiblePlaybackTarget(localPlayerID: "local"))
    }
    let hiddenSpeaker = Player(.object(["private": .bool(false), "hide_in_ui": .bool(true)]))
    #expect(!hiddenSpeaker.isVisiblePlaybackTarget(localPlayerID: nil))
}

@Test func queueArtworkSurvivesNestedTrackWithoutImages() throws {
    let queue = PlayerQueue(.object([
        "current_item": .object([
            "image": .object(["proxy_id": .string("album-fallback")]),
            "media_item": .object(["uri": .string("library://track/1"), "name": .string("Song")]),
        ]),
    ]))
    let server = try ServerAddress("https://music.example.com/assistant")
    #expect(queue.current?.name == "Song")
    #expect(queue.current?.artworkURL(server: server) == server.endpoint("imageproxy/album-fallback"))
}

@Test func playerFeaturesParseOnlyAdvertisedWireValues() throws {
    let raw = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"{"player_id":"speaker","supported_features":["play_media","set_members","volume_set","pause","seek","next_previous","future_feature",42,null]}"#
                .utf8
        )
    )
    let player = Player(raw)
    #expect(player.supportedFeatures == [.playMedia, .setMembers, .volumeSet, .pause, .seek, .nextPrevious])
    #expect(Player(.object([:])).supportedFeatures.isEmpty)
    #expect(Player(.object(["supported_features": .null])).supportedFeatures.isEmpty)
}

@Test func reportedSendspinVolumeDoesNotImplyVolumeControl() {
    let raw: JSONValue = .object([
        "player_id": .string("sendspin"), "available": .bool(true),
        "supported_features": .array([.string("play_media"), .string("set_members")]),
        "volume_control": .string("none"), "volume_level": .number(100), "group_volume": .null,
    ])
    let player = Player(raw)
    #expect(!player.canSetVolume)
    #expect(player.volume == nil)
    #expect(player.volumeTarget(in: [player]) == nil)
    let supported = Player(raw.merging([
        "supported_features": .array([.string("volume_set")]),
        "volume_control": .string("native"), "group_volume": .number(50),
    ]))
    #expect(supported.canSetVolume)
    #expect(supported.volume == 50)
    #expect(supported.volumeTarget(in: [supported])?.volumeCommand == "volume_set")
    let disabled = Player(supported.raw.merging(["volume_control": .string("none")]))
    #expect(disabled.volumeTarget(in: [disabled]) == nil)
}

@Test func groupVolumeUsesControllableMembersEvenWithoutLeaderVolumeFeature() {
    let leader = Player(.object([
        "player_id": .string("leader"), "available": .bool(true),
        "volume_control": .string("none"), "supported_features": .array([]),
        "group_members": .array([.string("leader"), .string("speaker")]), "group_volume": .number(35),
    ]))
    let member = Player(.object([
        "player_id": .string("speaker"), "available": .bool(true),
        "synced_to": .string("leader"), "group_volume": .null,
    ]))
    #expect(leader.volumeTarget(in: [leader, member]) == leader)
    #expect(member.volumeTarget(in: [leader, member]) == leader)
    #expect(leader.volumeCommand == "group_volume")
    #expect(member.volumeTarget(in: [member]) == nil)
    let unsupported = Player(leader.raw.merging(["group_volume": .null]))
    #expect(member.volumeTarget(in: [unsupported, member]) == nil)
    let dedicated = Player(leader.raw.merging(["type": .string("group"), "group_members": .array([])]))
    #expect(dedicated.volumeCommand == "group_volume")
}

@Test func queueControlsDoNotRequireNativeSendspinTransportFeatures() {
    let player = Player(.object([
        "player_id": .string("universal"), "active_source": .string("group"),
        "supported_features": .array([.string("play_media"), .string("set_members")]),
    ]))
    let queue = PlayerQueue(.object([
        "queue_id": .string("group"), "active": .bool(true),
        "current_item": .object(["duration": .number(200)]),
    ]))
    for command in ["play", "pause", "next", "previous", "seek", "shuffle", "repeat"] {
        #expect(player.supports(command, queue: queue))
        #expect(!player.supports(command, queue: nil))
    }
    #expect(!player.supports("shuffle", queue: PlayerQueue(queue.raw.merging(["is_dynamic": .bool(true)]))))
}

@Test func sourceCapabilitiesDisableUnsupportedTransport() {
    let player = Player(.object([
        "player_id": .string("speaker"), "active_source": .string("input"),
        "supported_features": .array([.string("seek"), .string("pause"), .string("next_previous")]),
        "source_list": .array([.object([
            "id": .string("input"), "can_play_pause": .bool(false), "can_seek": .bool(false),
            "can_next_previous": .bool(false), "can_shuffle": .bool(false), "can_repeat": .bool(false),
        ])]),
    ]))
    let queue = PlayerQueue(.object(["current_item": .object(["duration": .number(200)])]))
    for command in ["play", "pause", "next", "previous", "seek", "shuffle", "repeat"] {
        #expect(!player.supports(command, queue: queue))
    }
}

@Test func remoteProtocolResolvesToVisibleParentAfterLinking() {
    let protocolPlayer = Player(.object(["player_id": .string("sendspin"), "type": .string("protocol")]))
    let parent = Player(.object([
        "player_id": .string("universal"), "type": .string("player"),
        "output_protocols": .array([.object(["output_protocol_id": .string("sendspin")])]),
    ]))
    #expect(protocolPlayer.playbackTarget(in: [protocolPlayer, parent]) == parent)
    #expect(parent.playbackTarget(in: [protocolPlayer, parent]) == parent)
    #expect(protocolPlayer.playbackTarget(in: [protocolPlayer]) == nil)
}

@Test func groupingRequiresTargetSetMembersFeature() {
    let child = Player(.object([
        "player_id": .string("child"), "available": .bool(true), "can_group_with": .array([.string("parent")]),
    ]))
    let parent = Player(.object(["player_id": .string("parent"), "available": .bool(true)]))
    #expect(!child.canJoin(parent))
    #expect(child.canJoin(Player(parent.raw.merging(["supported_features": .array([.string("set_members")])]))))
}

@Test func leavingRequiresMutableGroupMembership() {
    let member = Player(.object([
        "player_id": .string("member"), "synced_to": .string("leader"),
    ]))
    let leader = Player(.object([
        "player_id": .string("leader"), "available": .bool(true),
        "supported_features": .array([.string("set_members")]),
    ]))
    #expect(member.canLeave(in: [leader, member]))
    #expect(!member.canLeave(in: [member]))
    #expect(!member.canLeave(in: [Player(leader.raw.merging(["supported_features": .array([])])), member]))
    #expect(!member.canLeave(in: [
        Player(leader.raw.merging(["static_group_members": .array([.string("member")])])),
        member,
    ]))
}

import Foundation
import MusicAssistantCore
import NowPlaying
import Testing
import UIKit

private actor PlaybackAPI: RemotePlaybackAPI {
    nonisolated let events: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    var commands: [(String, [String: JSONValue])] = []
    var connections = 0
    var activeQueue: JSONValue
    var players: [JSONValue]

    init(queue: JSONValue, players: [JSONValue] = [remotePlayer]) {
        self.players = players
        activeQueue = queue
        (events, continuation) = AsyncStream.makeStream()
    }

    func connect(server _: ServerAddress, token: String) async throws -> JSONValue {
        #expect(token == "test-token")
        connections += 1
        return .null
    }

    func command(_ name: String, args: [String: JSONValue]) async throws -> JSONValue {
        commands.append((name, args))
        switch name {
        case "players/all": return .array(players)
        case "player_queues/get_active_queue":
            // MA also resolves protocol_parent_id here; the queue remains owned
            // by its playable parent or group, never by the protocol child.
            guard players.contains(where: { $0["player_id"] == args["player_id"] }) else { return .null }
            return activeQueue
        default: return .null
        }
    }

    func disconnect() async {
        continuation.finish()
    }
}

/// MA 2.10.9: Sendspin supplies play_media/set_members, while MA's queue supplies
/// pause, skip and seek. Hardware speakers may be wrapped by a universal player.
private let remotePlayer: JSONValue = .object([
    "player_id": .string("selected-speaker"), "name": .string("Kitchen"),
    "type": .string("player"), "provider": .string("universal_player"), "available": .bool(true),
    "supported_features": .array([.string("play_media"), .string("set_members")]),
    "active_source": .string("group-leader"), "volume_control": .string("none"),
    "volume_level": .number(100), "group_volume": .null,
    "output_protocols": .array([.object(["output_protocol_id": .string("sendspin-speaker")])]),
])

private func attributes(
    state: String = "playing",
    resume: Double = 0,
    timestamp: Date = .now
) throws -> RemotePlaybackAttributes {
    try RemotePlaybackAttributes(
        server: ServerAddress("http://127.0.0.1:8095"),
        player: Player(remotePlayer),
        queue: PlayerQueue(.object([
            "queue_id": .string("group-leader"), "state": .string(state), "active": .bool(true),
            "elapsed_time": .number(0),
            "elapsed_time_last_updated": .number(timestamp.timeIntervalSince1970),
            "resume_pos": .number(resume),
            "current_item": .object(["duration": .number(200), "name": .string("Track")]),
        ])),
        timestamp: timestamp
    )
}

@MainActor @Test func remoteCommandsTargetSelectedPlayerAndSeekUsesCurrentGroup() async throws {
    let initial = try attributes()
    let activeQueue: JSONValue = .object([
        "queue_id": .string("new-group"), "state": .string("paused"), "active": .bool(true),
        "current_item": .object(["duration": .number(100), "name": .string("New Track")]),
    ])
    let api = PlaybackAPI(queue: activeQueue)
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in "test-token" })
    try await session.playback("pause")
    try await session.seek(to: 120)
    let commands = await api.commands
    #expect(commands.contains { $0.0 == "players/cmd/pause" && $0.1["player_id"] == .string("selected-speaker") })
    #expect(commands
        .contains {
            $0.0 == "player_queues/seek" && $0.1["queue_id"] == .string("new-group") && $0.1["position"] == .number(100)
        })
    #expect(await api.connections == 1)
}

@MainActor @Test func remoteCommandsRequireKeychainCredentials() async throws {
    let initial = try attributes()
    let api = PlaybackAPI(queue: initial.queue)
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in nil })
    await #expect(throws: (any Error).self) { try await session.playback("play") }
    #expect(await api.connections == 0)
    #expect(await api.commands.isEmpty)
}

@MainActor @Test func remoteSeekRejectsInvalidPositions() async throws {
    let initial = try attributes()
    let api = PlaybackAPI(queue: initial.queue)
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in "test-token" })
    for position in [Double.nan, .infinity, -1] {
        await #expect(throws: (any Error).self) { try await session.seek(to: position) }
    }
    #expect(await api.commands.allSatisfy { $0.0 != "player_queues/seek" })
}

@MainActor @Test func remoteAttributesRejectStaleAndDifferentSessions() throws {
    let initial = try attributes(state: "paused", resume: 67, timestamp: Date(timeIntervalSince1970: 100))
    let api = PlaybackAPI(queue: initial.queue)
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in nil })
    try session.update(attributes(timestamp: Date(timeIntervalSince1970: 90)))
    #expect(session.attributes.timestamp == initial.timestamp)
    #expect(!PlayerQueue(session.attributes.queue).isPlaying)
    let other = try RemotePlaybackAttributes(
        server: ServerAddress("http://other.local:8095"),
        player: Player(.object(["player_id": .string("another-speaker")])),
        queue: PlayerQueue(initial.queue)
    )
    session.update(other)
    #expect(session.attributes.id == initial.id)
    #expect(session.devices.first?.id == "selected-speaker")
    // Encoding the donated state must not expose authentication material.
    let data = try JSONEncoder().encode(initial)
    let decoded = try JSONDecoder().decode(RemotePlaybackAttributes.self, from: data)
    #expect(decoded.id == initial.id)
    #expect(PlayerQueue(decoded.queue).elapsed() == 67)
    #expect(!String(decoding: data, as: UTF8.self).contains("token"))
}

@Test func remoteAttributesDonateOnlyDisplayMetadata() throws {
    let raw: JSONValue = .object([
        "queue_id": .string("room"), "state": .string("playing"),
        "extra_attributes": .object(["token": .string("private-secret")]),
        "current_item": .object([
            "name": .string("Music"), "duration": .number(120),
            "streamdetails": .object(["path": .string("https://private-secret")]),
        ]),
    ])
    let value = try RemotePlaybackAttributes(
        server: ServerAddress("http://127.0.0.1:8095"),
        player: Player(.object(["player_id": .string("room")])),
        queue: PlayerQueue(raw)
    )
    let encoded = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    #expect(!encoded.contains("private-secret"))
    #expect(PlayerQueue(value.queue).current?.name == "Music")
}

@Test(arguments: [false, true])
func remoteArtworkAcceptsPNGWithAndWithoutTransparency(opaque: Bool) throws {
    let format = UIGraphicsImageRendererFormat()
    format.opaque = opaque
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
    let data = renderer.pngData { context in
        context.cgContext.setFillColor(UIColor.red.cgColor)
        context.cgContext.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
    }
    for size in [CGSize(width: 32, height: 32), .zero, CGSize(width: 4096, height: 4096)] {
        _ = try RemoteArtwork.representation(data: data, size: size)
    }
}

@Test func remoteArtworkRejectsInvalidImageData() {
    #expect(throws: ArtworkRepresentation.ArtworkRepresentationError.self) {
        try RemoteArtwork.representation(data: Data("not an image".utf8), size: CGSize(width: 64, height: 64))
    }
}

@Test func remoteArtworkAcceptsWebP() throws {
    // A generated 2 × 2 lossless WebP, embedded to avoid network-dependent tests.
    let data = try #require(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA4AAAAvAUAAAAcQEf0PRET/Aw=="))
    _ = try RemoteArtwork.representation(data: data, size: CGSize(width: 64, height: 64))
}

@Test func remoteArtworkURLSurvivesDonationAndRefresh() throws {
    let server = try ServerAddress("https://music.example.com/assistant")
    let queue = PlayerQueue(.object([
        "queue_id": .string("room"),
        "current_item": .object(["media_item": .object([
            "uri": .string("library://track/1"), "name": .string("Track"),
            "metadata": .object(["images": .array([.object([
                "type": .string("thumb"), "proxy_id": .string("album-art"),
            ])])]),
        ])]),
    ]))
    let initial = RemotePlaybackAttributes(
        server: server,
        player: Player(.object(["player_id": .string("room")])),
        queue: queue
    )
    var decoded = try JSONDecoder().decode(RemotePlaybackAttributes.self, from: JSONEncoder().encode(initial))
    let expected = server.endpoint("imageproxy/album-art")
    #expect(PlayerQueue(decoded.queue).current?.artworkURL(server: server) == expected)
    decoded.updateQueue(queue)
    #expect(PlayerQueue(decoded.queue).current?.artworkURL(server: server) == expected)
}

@Test func queueLevelArtworkSurvivesDonationAndRefresh() throws {
    let server = try ServerAddress("https://music.example.com/assistant")
    let queue = PlayerQueue(.object([
        "queue_id": .string("room"),
        "current_item": .object([
            "image": .object(["proxy_id": .string("album-art")]),
            "media_item": .object(["uri": .string("library://track/1"), "name": .string("Track")]),
        ]),
    ]))
    var value = RemotePlaybackAttributes(
        server: server,
        player: Player(.object(["player_id": .string("room")])),
        queue: queue
    )
    value = try JSONDecoder().decode(RemotePlaybackAttributes.self, from: JSONEncoder().encode(value))
    #expect(PlayerQueue(value.queue).current?.artworkURL(server: server) == server.endpoint("imageproxy/album-art"))
    value.updateQueue(queue)
    #expect(PlayerQueue(value.queue).current?.artworkURL(server: server) == server.endpoint("imageproxy/album-art"))
}

private actor ArtworkFetcher {
    var attempts = 0
    let data: Data
    init(data: Data) {
        self.data = data
    }

    func fetch(_: URL) throws -> Data {
        attempts += 1
        if attempts == 1 {
            throw URLError(.networkConnectionLost)
        }
        return data
    }
}

@MainActor @Test func remoteArtworkRetriesBeforePublishingStableIdentity() async throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
    let data = renderer.pngData { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
    let fetcher = ArtworkFetcher(data: data)
    var initial = try attributes()
    initial.queue = initial.queue.merging([
        "current_item": .object([
            "uri": .string("track://1"), "image": .object(["path": .string("https://example.com/art")]),
        ]),
    ])
    let api = PlaybackAPI(queue: initial.queue)
    let session = RemotePlaybackSession(
        attributes: initial,
        api: api,
        readToken: { _ in "test-token" },
        fetchArtwork: { try await fetcher.fetch($0) }
    )
    #expect(session.content?.artwork == nil)
    for _ in 0 ..< 40 {
        if session.content?.artwork != nil {
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(session.content?.artwork?.id == "https://example.com/art")
    #expect(await fetcher.attempts == 2)
}

@MainActor @Test func remoteSendspinProtocolUsesPlayableParentAndCurrentQueue() async throws {
    let initial = try RemotePlaybackAttributes(
        server: ServerAddress("http://127.0.0.1:8095"),
        player: Player(remotePlayer.merging(["player_id": .string("sendspin-speaker"), "type": .string("protocol")])),
        queue: PlayerQueue(attributes().queue)
    )
    let api = PlaybackAPI(queue: initial.queue, players: [remotePlayer, .object([
        "player_id": .string("sendspin-speaker"), "type": .string("protocol"),
        "protocol_parent_id": .string("selected-speaker"), "available": .bool(true),
    ])])
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in "test-token" })
    for command in ["pause", "play", "next", "previous"] {
        try await session.playback(command)
    }
    try await session.seek(to: 42)
    let commands = await api.commands
    #expect(commands.filter { $0.0.hasPrefix("players/cmd/") }.allSatisfy {
        $0.1["player_id"] == .string("selected-speaker")
    })
    #expect(commands.contains { $0.0 == "player_queues/seek" && $0.1["queue_id"] == .string("group-leader") })
    #expect(session.devices.first?.id == "selected-speaker")
    #expect(session.attributes.id == initial.id)
}

@MainActor @Test func remoteCommandsRespectSourceCapabilities() async throws {
    let initial = try attributes()
    let unsupported = remotePlayer.merging([
        "active_source": .string("input"),
        "source_list": .array([.object([
            "id": .string("input"), "can_play_pause": .bool(false), "can_seek": .bool(false),
            "can_next_previous": .bool(false),
        ])]),
    ])
    let api = PlaybackAPI(queue: initial.queue, players: [unsupported])
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in "test-token" })
    for command in ["pause", "play", "next", "previous"] {
        await #expect(throws: (any Error).self) { try await session.playback(command) }
    }
    await #expect(throws: (any Error).self) { try await session.seek(to: 20) }
    #expect(await api.commands.allSatisfy { !$0.0.hasPrefix("players/cmd/") && $0.0 != "player_queues/seek" })
}

@MainActor private final class Publication: RemotePlaybackPublication {
    let id: String
    var updates = 0
    var ends = 0
    var primaryRequests = 0
    var failPrimary = true
    init(id: String) {
        self.id = id
    }

    func update(_: RemotePlaybackAttributes) async throws {
        updates += 1
    }

    func end() async throws {
        ends += 1
    }

    func requestToBecomeSystemPrimary() async throws {
        primaryRequests += 1
        if failPrimary {
            throw RemoteMediaSessionError.internalFailure
        }
    }
}

@MainActor private func waitForPublication(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
}

@MainActor @Test func pausedRemoteSelectionPublishesAndFailedPrimaryRequestRetries() async throws {
    let initial = try attributes(state: "paused")
    let publication = Publication(id: initial.id)
    var starts = 0
    let publisher = RemotePlaybackPublisher(recover: { [] }, start: { _ in
        starts += 1
        return publication
    }, isForeground: { true })
    publisher.update(initial)
    try await waitForPublication { publication.primaryRequests == 1 }
    #expect(starts == 1)
    publication.failPrimary = false
    publisher.update(initial)
    try await waitForPublication { publication.primaryRequests == 2 }
    publisher.update(initial)
    try await waitForPublication { publication.updates == 2 }
    #expect(publication.primaryRequests == 2)
    publisher.update(nil)
    try await waitForPublication { publication.ends == 1 }
}

@MainActor @Test func remoteSendspinArtworkSurvivesParentResolutionAndServerRefresh() async throws {
    let imageID = String(repeating: "a", count: 64)
    let server = try ServerAddress("http://127.0.0.1:8095")
    let queue = PlayerQueue(.object([
        "queue_id": .string("group-leader"), "state": .string("playing"), "active": .bool(true),
        "current_item": .object([
            "image": .object(["proxy_id": .string(imageID)]), "duration": .number(200),
            "media_item": .object(["uri": .string("library://track/1"), "name": .string("Sendspin Track")]),
        ]),
    ]))
    let initial = RemotePlaybackAttributes(server: server, player: Player(remotePlayer), queue: queue)
    let api = PlaybackAPI(queue: queue.raw)
    let image = try #require(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA4AAAAvAUAAAAcQEf0PRET/Aw=="))
    let expected = server.endpoint("imageproxy/\(imageID)")
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in "test-token" }, fetchArtwork: {
        #expect($0 == expected)
        return image
    })
    try await session.playback("pause")
    try await waitForPublication { session.content?.artwork != nil }
    #expect(session.content?.artwork?.id == expected.absoluteString)
    #expect(PlayerQueue(session.attributes.queue).current?.name == "Sendspin Track")
    #expect(PlayerQueue(session.attributes.queue).current?.artworkURL(server: server) == expected)
}

@MainActor @Test func remotePrimaryWaitsForForegroundAndPlayerChangesEndOldSession() async throws {
    let initial = try attributes()
    let next = try RemotePlaybackAttributes(
        server: ServerAddress("http://127.0.0.1:8095"),
        player: Player(remotePlayer.merging(["player_id": .string("other-room")])),
        queue: PlayerQueue(initial.queue)
    )
    let old = Publication(id: "previous-process")
    var created: [Publication] = []
    var foreground = false
    let publisher = RemotePlaybackPublisher(recover: { [old] }, start: { attributes in
        let publication = Publication(id: attributes.id)
        publication.failPrimary = false
        created.append(publication)
        return publication
    }, isForeground: { foreground })
    publisher.update(initial)
    try await waitForPublication { created.count == 1 }
    #expect(old.ends == 1)
    #expect(created[0].primaryRequests == 0)
    foreground = true
    publisher.update(initial)
    try await waitForPublication { created[0].primaryRequests == 1 }
    publisher.update(next)
    try await waitForPublication { created.count == 2 }
    #expect(created[0].ends == 1)
    #expect(created[1].primaryRequests == 1)
    publisher.update(nil)
    try await waitForPublication { created[1].ends == 1 }
}

@MainActor @Test func remoteClockUsesTheAttributesTimestampAcrossRepeatedReads() async throws {
    var initial = try attributes(timestamp: .now.addingTimeInterval(-5))
    initial.queue = initial.queue.merging(["elapsed_time": .number(20)])
    let api = PlaybackAPI(queue: initial.queue)
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in nil })
    let first = session.queue.elapsed()
    #expect(abs(first - 25) < 1)
    #expect(session.queue.receivedAt == initial.timestamp)
    try await Task.sleep(for: .milliseconds(50))
    let second = session.queue.elapsed()
    #expect(second > first)
}

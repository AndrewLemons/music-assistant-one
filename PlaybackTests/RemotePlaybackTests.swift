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

    init(queue: JSONValue) {
        activeQueue = queue
        (events, continuation) = AsyncStream.makeStream()
    }
    func connect(server: ServerAddress, token: String) async throws -> JSONValue {
        #expect(token == "test-token")
        connections += 1
        return .null
    }
    func command(_ name: String, args: [String: JSONValue]) async throws -> JSONValue {
        commands.append((name, args))
        return name == "player_queues/get_active_queue" ? activeQueue : .null
    }
    func disconnect() async { continuation.finish() }
}

private func attributes(state: String = "playing", resume: Double = 0, timestamp: Date = .now) throws -> RemotePlaybackAttributes {
    RemotePlaybackAttributes(server: try ServerAddress("http://127.0.0.1:8095"),
        player: Player(.object(["player_id": .string("selected-speaker"), "name": .string("Kitchen")])),
        queue: PlayerQueue(.object([
            "queue_id": .string("group-leader"), "state": .string(state),
            "elapsed_time": .number(0), "elapsed_time_last_updated": .number(timestamp.timeIntervalSince1970),
            "resume_pos": .number(resume),
            "current_item": .object(["duration": .number(200), "name": .string("Track")])
        ])), timestamp: timestamp)
}

@MainActor @Test func remoteCommandsTargetSelectedPlayerAndSeekUsesCurrentGroup() async throws {
    let initial = try attributes()
    let activeQueue: JSONValue = .object([
        "queue_id": .string("new-group"), "state": .string("paused"),
        "current_item": .object(["duration": .number(100), "name": .string("New Track")])
    ])
    let api = PlaybackAPI(queue: activeQueue)
    let session = RemotePlaybackSession(attributes: initial, api: api, readToken: { _ in "test-token" })
    try await session.playback("pause")
    try await session.seek(to: 120)
    let commands = await api.commands
    #expect(commands.contains { $0.0 == "players/cmd/pause" && $0.1["player_id"] == .string("selected-speaker") })
    #expect(commands.contains { $0.0 == "player_queues/seek" && $0.1["queue_id"] == .string("new-group") && $0.1["position"] == .number(100) })
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
    session.update(try attributes(timestamp: Date(timeIntervalSince1970: 90)))
    #expect(session.attributes.timestamp == initial.timestamp)
    #expect(!PlayerQueue(session.attributes.queue).isPlaying)
    let other = RemotePlaybackAttributes(server: try ServerAddress("http://other.local:8095"),
        player: Player(.object(["player_id": .string("another-speaker")])),
        queue: PlayerQueue(initial.queue))
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
            "streamdetails": .object(["path": .string("https://private-secret")])
        ])
    ])
    let value = RemotePlaybackAttributes(server: try ServerAddress("http://127.0.0.1:8095"),
        player: Player(.object(["player_id": .string("room")])), queue: PlayerQueue(raw))
    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
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
                "type": .string("thumb"), "proxy_id": .string("album-art")
            ])])])
        ])])
    ]))
    let initial = RemotePlaybackAttributes(server: server,
        player: Player(.object(["player_id": .string("room")])), queue: queue)
    var decoded = try JSONDecoder().decode(RemotePlaybackAttributes.self, from: JSONEncoder().encode(initial))
    let expected = server.endpoint("imageproxy/album-art")
    #expect(PlayerQueue(decoded.queue).current?.artworkURL(server: server) == expected)
    decoded.updateQueue(queue)
    #expect(PlayerQueue(decoded.queue).current?.artworkURL(server: server) == expected)
}

import Foundation
@testable import MusicAssistantCore
import Testing

private final class FixtureServer {
    let process = Process()
    let address: ServerAddress
    init() throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process
            .arguments = [Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data()
        while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty,
              next != Data([10])
        {
            bytes.append(next)
        }
        let port = String(decoding: bytes, as: UTF8.self)
        address = try ServerAddress("http://127.0.0.1:\(port)")
    }

    deinit { process.terminate() }
}

@Test func websocketCorrelatesConcurrentCommandsAndPartialResults() async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    let info = try await client.connect(server: server.address, token: "fixture-token")
    #expect(info["schema_version"].double == 65)
    async let first = client.command("echo", args: ["value": .string("first")])
    async let second = client.command("echo", args: ["value": .string("second")])
    #expect(try await first["value"].string == "first")
    #expect(try await second["value"].string == "second")
    #expect(try await client.command("partial") == .array([.number(1), .number(2), .number(3)]))
    var events = client.events.makeAsyncIterator()
    #expect(await events.next()?["event"].string == "player_updated")
    await client.disconnect()
}

@Test func websocketRejectsBadAuthenticationAndRecovers() async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    await #expect(throws: (any Error).self) { try await client.connect(server: server.address, token: "wrong") }
    _ = try await client.connect(server: server.address, token: "fixture-token")
    await #expect(throws: (any Error).self) { try await client.command("fail") }
    #expect(try await client.command("echo", args: ["ok": .bool(true)])["ok"].bool == true)
    await client.disconnect()
}

@Test func cancellationAndDisconnectResolvePendingRequests() async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    _ = try await client.connect(server: server.address, token: "fixture-token")
    let pending = Task { try await client.command("wait") }
    try await Task.sleep(for: .milliseconds(100))
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
    let dropped = Task { try await client.command("wait") }
    try await Task.sleep(for: .milliseconds(100))
    await client.disconnect()
    await #expect(throws: (any Error).self) { try await dropped.value }
}

@MainActor @Test func paginationRetrievesCompleteLibraryAndSearchOverWebSocket() async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    _ = try await client.connect(server: server.address, token: "fixture-token")
    let library = MediaPager()
    library.reset(.library(collection: "tracks", search: "", order: "sort_name"))
    for _ in 0 ..< 3 {
        await library.loadNext { request, offset, limit in
            try await request.items(in: client.command(
                request.command,
                args: request.arguments(offset: offset, limit: limit)
            ))
        }
    }
    #expect(library.items.count == 237)
    #expect(library.items.last?.name == "Track 236")
    #expect(!library.hasMore)
    library.reset(.library(collection: "tracks", search: "Track 234", order: "sort_name"))
    await library.loadNext { request, offset, limit in
        try await request.items(in: client.command(
            request.command,
            args: request.arguments(offset: offset, limit: limit)
        ))
    }
    #expect(library.items.map(\.name) == ["Track 234"])
    let search = MediaPager(pageSize: 25)
    search.reset(.search(query: "Match", kind: "track"))
    for _ in 0 ..< 4 {
        await search.loadNext { request, offset, limit in
            try await request.items(in: client.command(
                request.command,
                args: request.arguments(offset: offset, limit: limit)
            ))
        }
    }
    #expect(search.items.count == 123)
    #expect(!search.hasMore)
    #expect(search.error == nil)
    await client.disconnect()
}

@Test func independentAudioDiscoversOptionalSupportAndRestrictsTicketsToServerOrigin() async throws {
    let fixture = try FixtureServer()
    let client = IndependentAudioClient(server: fixture.address, token: "fixture-token")
    #expect(try await client.isAvailable())
    let track = MediaItem(.object(["uri": .string("library://track/one")]))
    let source = try await client.resolve(track)
    #expect(source.url.host == fixture.address.baseURL.host)
    #expect(source.url.port == fixture.address.baseURL.port)
    #expect(source.url.path.hasPrefix("/one/v1/audio/"))
    #expect(!source.isProgressive)
    // Current companions stream while preparing, and hand over the complete file once ready.
    let streamed = try await client.resolve(MediaItem(.object(["uri": .string("library://track/streamed")])))
    #expect(streamed.isProgressive)
    #expect(streamed.url.path == "/one/v1/stream/22222222-2222-4222-8222-222222222222/index.m3u8")
    let prepared = try await client.resolve(MediaItem(.object(["uri": .string("library://track/prepared")])))
    #expect(!prepared.isProgressive && prepared.url.path.hasSuffix(".flac"))
    await #expect(throws: (any Error).self) {
        try await client.resolve(MediaItem(.object(["uri": .string("library://track/escaped")])))
    }
    let absent = try IndependentAudioClient(
        server: ServerAddress(fixture.address.baseURL.absoluteString + "/missing"),
        token: "fixture-token"
    )
    #expect(try await !absent.isAvailable())
    let unauthorized = IndependentAudioClient(server: fixture.address, token: "incorrect")
    await #expect(throws: (any Error).self) { try await unauthorized.isAvailable() }
    let external = MediaItem(.object(["uri": .string("library://track/external")]))
    await #expect(throws: (any Error).self) { try await client.resolve(external) }
}

@Test(arguments: [-5.0, 5])
func sendspinLinkedQueueSeekAndFlowAdvanceUseWirePayloads(_ skew: Double) async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    _ = try await client.connect(server: server.address, token: "fixture-token")
    let raw = try await client.command("fixture/playback", args: ["skew": .number(skew)])
    let received = Date.now
    var queue = PlayerQueue(raw, receivedAt: received)
    #expect(queue.elapsed(at: received) == 80)
    // A protocol id is not a queue id: reproduce MA's actual rejection.
    await #expect(throws: (any Error).self) {
        try await client.command("player_queues/seek", args: [
            "queue_id": .string("sendspin-client"), "position": .number(100),
        ])
    }
    let target = TransportControl.Target(queueID: "sendspin-client", playerID: "sendspin-client")
    var active = try await client.command(
        "player_queues/get_active_queue",
        args: ["player_id": .string(target.playerID)]
    )
    var resolved = try target.resolvingActiveQueue(active)
    #expect(resolved.queueID == "universal-sendspin")
    _ = try await client.command("player_queues/seek", args: [
        "queue_id": .string(resolved.queueID), "position": .number(100),
    ])
    var events = client.events.makeAsyncIterator()
    for _ in 0 ..< 2 {
        let event1 = try #require(await events.next())
        queue = try #require(queue.applying(event1))
        #expect(abs(queue.elapsed() - 100) < 0.2)
    }
    _ = try await client.command("players/cmd/pause", args: ["player_id": .string(target.playerID)])
    let event2 = try #require(await events.next())
    queue = try #require(queue.applying(event2))
    #expect(!queue.isPlaying)
    #expect(queue.elapsed(at: .now.addingTimeInterval(20)) == 100)
    _ = try await client.command("players/cmd/play", args: ["player_id": .string(target.playerID)])
    let event3 = try #require(await events.next())
    queue = try #require(queue.applying(event3))
    #expect(queue.isPlaying)
    _ = try await client.command("fixture/advance")
    let event4 = try #require(await events.next())
    queue = try #require(queue.applying(event4))
    #expect(queue.itemID == "second")
    #expect(queue.duration == 120)
    #expect(abs(queue.elapsed() - 0.25) < 0.2, "Do not use flow stream elapsed or the preceding item's position")
    // Group changes must resolve again instead of sending to the cached queue id.
    _ = try await client.command("fixture/regroup")
    active = try await client.command("player_queues/get_active_queue", args: ["player_id": .string(target.playerID)])
    resolved = try target.resolvingActiveQueue(active)
    #expect(resolved.queueID == "sendspin-group")
    _ = try await client.command("player_queues/seek", args: [
        "queue_id": .string(resolved.queueID), "position": .number(10),
    ])
    await client.disconnect()
}

@Test(arguments: ["sendspin-this-device", "ordinary-speaker"])
func unlinkedPlayersUseTheirActiveQueueForSeekAndNext(_ playerID: String) async throws {
    let server = try FixtureServer()
    let client = MusicAssistantClient()
    _ = try await client.connect(server: server.address, token: "fixture-token")
    let raw = try await client.command("fixture/playback", args: [
        "linked": .bool(false), "player_id": .string(playerID), "flow": .bool(playerID != "ordinary-speaker"),
    ])
    var queue = PlayerQueue(raw)
    let target = try TransportControl.Target(queueID: playerID, playerID: playerID).resolvingActiveQueue(raw)
    #expect(target.queueID == playerID)
    _ = try await client.command(
        "player_queues/seek",
        args: ["queue_id": .string(target.queueID), "position": .number(90)]
    )
    var events = client.events.makeAsyncIterator()
    for _ in 0 ..< 2 {
        let event5 = try #require(await events.next())
        queue = try #require(queue.applying(event5))
    }
    #expect(abs(queue.elapsed() - 90) < 0.2)
    _ = try await client.command("players/cmd/next", args: ["player_id": .string(playerID)])
    let event6 = try #require(await events.next())
    queue = try #require(queue.applying(event6))
    #expect(queue.itemID == "second")
    #expect(queue.elapsed() < 0.2)
    await client.disconnect()
}

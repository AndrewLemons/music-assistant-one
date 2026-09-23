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

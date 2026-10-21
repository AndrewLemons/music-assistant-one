import Foundation
import MusicAssistantCore
import Network
import Testing

/// A real loopback endpoint exercises background delivery and native FLAC decoding.
private final class AudioHTTPFixture: @unchecked Sendable {
    static let audio =
        Data(
            base64Encoded: "ZkxhQwAAACIQABAAAAAOAAAQCsRC8AAArETSsSAZkBm2OdWn4rNGPpyXhAAAKCAAAAByZWZlcmVuY2UgbGliRkxBQyAxLjUuMCAyMDI1MDIxMQAAAAD/+MkYAMIAAAAAAAC47v/4yRgBxQAAAAAAAC+b//jJGALMAAAAAAAAFgH/+MkYA8sAAAAAAACBdP/4yRgE3gAAAAAAAGU1//jJGAXZAAAAAAAA8kD/+MkYBtAAAAAAAADL2v/4yRgH1wAAAAAAAFyv//jJGAj6AAAAAAAAg13/+MkYCf0AAAAAAAAUKP/4eRgKDEOzAAAAAAAA4sk="
        )!
    let listener: NWListener
    let body: Data
    init(body: Data? = nil) throws {
        self.body = body ?? Self.audio
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> ServerAddress {
        let audioData = body
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                guard let data else { connection.cancel(); return }
                let request = String(decoding: data, as: UTF8.self)
                let audio = request.contains(".flac")
                let body = audio ? audioData :
                    Data("{\"path\":\"one/v1/audio/11111111-1111-4111-8111-111111111111.flac\"}".utf8)
                let type = audio ? "audio/flac" : "application/json"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(header.utf8) + body,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return try ServerAddress("http://127.0.0.1:\(port)")
    }

    deinit { listener.cancel() }
}

@MainActor @Suite(.serialized) struct IndependentPlaybackTests {
    private func media(_ id: String) -> MediaItem {
        MediaItem(.object(["uri": .string("library://track/" + id), "name": .string(id), "duration": .number(1)]))
    }

    @Test func validatesAndDownloadsRealAudioThenPlaysWithNoNetwork() async throws {
        let server = try AudioHTTPFixture()
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "fixture")
        let song = media("offline")
        try await downloads.enqueue([song])
        for _ in 0 ..< 200 {
            if downloads.isDownloaded(song) || downloads.jobs.first?.state == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(downloads.jobs.first?.failure == nil)
        #expect(downloads.isDownloaded(song))
        let file = try #require(await downloads.file(for: song))
        #expect(FileManager.default.fileExists(atPath: file.path))
        server.listener.cancel()
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(
            access: IndependentAudioClient(server: address, token: "fixture"),
            store: downloads.store
        )
        player.online = false
        player.insert([song, song], option: "replace")
        let first = player.state.currentID
        for _ in 0 ..< 100 {
            if player.state.currentID != first {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.error == nil)
        #expect(player.state.currentID != first)
        player.pause()
        #expect(!player.wantsPlayback)
        player.stop(clear: true)
        try await downloads.erase()
    }

    @Test func invalidDownloadsRemainRetryableAndNeverBecomeOfflineMusic() async throws {
        let server = try AudioHTTPFixture(body: Data("<html>Not audio</html>".utf8))
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "bad-file-fixture")
        let song = media("broken")
        try await downloads.enqueue([song])
        for _ in 0 ..< 100 {
            if downloads.jobs.first?.state == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(downloads.jobs.first?.state == .failed)
        #expect(!downloads.isAvailable(song))
        #expect(try await downloads.file(for: song) == nil)
        let job = try #require(downloads.jobs.first)
        downloads.cancel(job)
        #expect(downloads.jobs.isEmpty)
        try await downloads.erase()
    }

    @Test func pausingOneDownloadLeavesOtherJobsAbleToFinish() async throws {
        let server = try AudioHTTPFixture()
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "pause-fixture")
        let songs = [media("first"), media("second"), media("third")]
        try await downloads.enqueue(songs)
        let first = try #require(downloads.jobs.first)
        downloads.pause(first)
        #expect(downloads.jobs.first?.state == .paused)
        for _ in 0 ..< 200 {
            if downloads.isDownloaded(songs[1]), downloads.isDownloaded(songs[2]) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(downloads.isDownloaded(songs[1]) && downloads.isDownloaded(songs[2]))
        // A complete file can race the pause. Keep that valid completion; otherwise
        // resume the preserved system task and verify that its bytes aren't lost.
        if let paused = downloads.jobs.first {
            downloads.retry(paused)
        }
        for _ in 0 ..< 200 {
            if downloads.isDownloaded(songs[0]) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(downloads.isDownloaded(songs[0]))
        try await downloads.erase()
    }

    @Test func restoresPausedQueueAndKeepsSeekPositionBeforeAudioLoads() async throws {
        let server = try AudioHTTPFixture()
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "restore-fixture")
        var state = DevicePlaybackQueue()
        let song = MediaItem(.object([
            "uri": .string("library://track/long"),
            "name": .string("Long"),
            "duration": .number(100),
        ]))
        state.insert([song, media("next")]); state.seek(67)
        let store = try #require(downloads.store)
        try await store.saveQueue(state)
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(access: IndependentAudioClient(server: address, token: "restore-fixture"), store: store)
        #expect(!player.wantsPlayback)
        #expect(player.state.position == 67)
        await player.seek(42)
        #expect(player.state.position == 42)
        #expect(!player.wantsPlayback)
        player.stop(clear: true)
        try await downloads.erase()
    }
}

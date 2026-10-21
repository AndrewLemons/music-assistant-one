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
    static let longAudio =
        Data(
            base64Encoded: "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"
        )!
    let listener: NWListener
    let body: Data
    let resolveDelay: Double
    private let lock = NSLock()
    private var resolvedURIs: [String] = []
    private var resolvedResponses: [String] = []
    private var fileURIs: [String] = []
    private var heldResponses: [@Sendable () -> Void] = []
    private var holdsFiles = false
    private var requestedArtwork = 0

    var artworkRequests: Int {
        lock.withLock { requestedArtwork }
    }

    func resolutions(for item: MediaItem) -> Int {
        lock.withLock { resolvedURIs.filter { $0 == item.uri }.count }
    }

    func resolutionResponses(for item: MediaItem) -> Int {
        lock.withLock { resolvedResponses.filter { $0 == item.uri }.count }
    }

    func fileRequests(for item: MediaItem) -> Int {
        lock.withLock { fileURIs.filter { $0 == item.uri }.count }
    }

    func holdFiles() {
        lock.withLock { holdsFiles = true }
    }

    func releaseFiles() {
        let responses = lock.withLock {
            holdsFiles = false
            let responses = heldResponses
            heldResponses = []
            return responses
        }
        responses.forEach { $0() }
    }

    init(body: Data? = nil, resolveDelay: Double = 0) throws {
        self.body = body ?? Self.audio
        self.resolveDelay = resolveDelay
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> ServerAddress {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receive(connection)
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

    private func receive(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            guard let data else { connection.cancel(); return }
            let bytes = buffered + data
            let request = String(decoding: bytes, as: UTF8.self)
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                receive(connection, buffered: bytes); return
            }
            let length = request.components(separatedBy: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            })?.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= boundary.upperBound + length else {
                receive(connection, buffered: bytes); return
            }
            let audio = request.contains(".flac")
            let artwork = request.hasPrefix("GET /art.jpg ")
            if artwork {
                lock.withLock { requestedArtwork += 1 }
            }
            var resolvedURI: String?
            if !audio, let json = request.components(separatedBy: "\r\n\r\n").last,
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let uri = object["uri"]
            {
                lock.withLock { resolvedURIs.append(uri) }
                resolvedURI = uri
            }
            var body = audio ? body :
                Data("{\"path\":\"one/v1/audio/\(UUID().uuidString).flac\"}".utf8)
            let type = audio ? "audio/flac" : "application/json"
            var status = "200 OK"
            var extra = "Accept-Ranges: bytes\r\n"
            if audio, let range = request.components(separatedBy: "\r\n").first(where: {
                $0.lowercased().hasPrefix("range: bytes=")
            })?.components(separatedBy: "=").last {
                let parts = range.split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(parts.first ?? "") ?? 0
                let end = min(Int(parts.last ?? "") ?? (body.count - 1), body.count - 1)
                if start <= end, start >= 0 {
                    extra += "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
                    body = body.subdata(in: start ..< end + 1)
                    status = "206 Partial Content"
                }
            }
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
            if request.hasPrefix("HEAD ") {
                body = Data()
            }
            let payload = Data(header.utf8) + body
            let uri = resolvedURI
            let send: @Sendable () -> Void = { [weak self] in
                connection.send(
                    content: payload, contentContext: .finalMessage,
                    completion: .contentProcessed { [weak self] _ in
                        if let uri {
                            self?.lock.withLock { self?.resolvedResponses.append(uri) }
                        }
                        connection.cancel()
                    }
                )
            }
            if let target = request.split(separator: " ").dropFirst().first,
               let uri = URLComponents(string: "http://fixture" + target)?.queryItems?.first(where: {
                   $0.name == "uri"
               })?.value
            {
                let held = lock.withLock {
                    fileURIs.append(uri)
                    guard holdsFiles else { return false }
                    heldResponses.append(send)
                    return true
                }
                if held {
                    return
                }
            }
            let delay = artwork ? 2 : audio ? 0 : resolveDelay
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: send)
        }
    }

    deinit { listener.cancel() }
}

@MainActor @Suite(.serialized) struct IndependentPlaybackTests {
    private func media(_ id: String) -> MediaItem {
        MediaItem(.object(["uri": .string("library://track/" + id), "name": .string(id), "duration": .number(1)]))
    }

    @Test func manualNextReusesThePreparedItemWithoutResolvingItAgain() async throws {
        let server = try AudioHTTPFixture(body: AudioHTTPFixture.longAudio, resolveDelay: 0.25)
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(access: IndependentAudioClient(server: address, token: "skip-fixture"), store: nil)
        player.online = true
        let songs = ["first", "second", "third"].map { id in
            MediaItem(media(id).raw.merging(["duration": .number(12)]))
        }
        player.insert(songs, option: "replace")
        defer { player.stop(clear: true) }
        for _ in 0 ..< 100 {
            if server.resolutionResponses(for: songs[1]) > 0, !player.isBuffering {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Let the loopback response reach AVQueuePlayer before the user presses Next.
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.resolutions(for: songs[1]) == 1)
        // Edits that leave the successor unchanged must preserve its prepared audio.
        player.insert([media("appended")], option: "add")
        player.setRepeat("all")
        let started = ContinuousClock.now
        player.next()
        #expect(player.state.current?.media.uri == songs[1].uri)
        for _ in 0 ..< 100 {
            if server.resolutions(for: songs[2]) > 0, !player.isBuffering {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("Prepared skip completed in \(started.duration(to: .now))")
        #expect(!player.isBuffering)
        #expect(server.resolutions(for: songs[1]) == 1)
        #expect(server.resolutions(for: songs[2]) == 1)
    }

    @Test func currentAndNextCacheRequestsStartWithoutWaitingForACompleteSong() async throws {
        let server = try AudioHTTPFixture(body: AudioHTTPFixture.longAudio)
        server.holdFiles()
        defer { server.releaseFiles() }
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "concurrent-cache-fixture")
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(
            access: IndependentAudioClient(server: address, token: "concurrent-cache-fixture"),
            store: downloads.store
        )
        player.online = true
        let songs = ["current", "upcoming"].map { MediaItem(media($0).raw.merging(["duration": .number(12)])) }
        player.insert(songs, option: "replace")
        for _ in 0 ..< 100 {
            if server.fileRequests(for: songs[0]) > 0, server.fileRequests(for: songs[1]) > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Neither full-file response has been released. Both requests must already exist.
        #expect(server.fileRequests(for: songs[0]) == 1)
        #expect(server.fileRequests(for: songs[1]) == 1)
        player.stop(clear: true)
        server.releaseFiles()
        try await downloads.erase()
    }

    @Test func cancelledPreparationCannotRemoveItsReplacementFromDeduplication() async throws {
        let server = try AudioHTTPFixture(body: AudioHTTPFixture.longAudio)
        server.holdFiles()
        defer { server.releaseFiles() }
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "cache-replacement-fixture")
        let song = MediaItem(media("replacement").raw.merging(["duration": .number(12)]))
        let original = Task { try await downloads.prepare(song, protecting: [song.uri]) }
        for _ in 0 ..< 100 {
            if server.fileRequests(for: song) > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        downloads.cancelPreparation(except: [])
        let replacement = Task { try await downloads.prepare(song, protecting: [song.uri]) }
        _ = await original.result
        for _ in 0 ..< 100 {
            if server.fileRequests(for: song) >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let shared = Task { try await downloads.prepare(song, protecting: [song.uri]) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.fileRequests(for: song) == 2)
        server.releaseFiles()
        #expect(try await replacement.value == shared.value)
        try await downloads.erase()
    }

    @Test func completedSeekAllowsPlaybackPositionToAdvanceAgain() async throws {
        let server = try AudioHTTPFixture(body: AudioHTTPFixture.longAudio)
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "seek-fixture")
        let song = MediaItem(media("seek").raw.merging(["duration": .number(12)]))
        _ = try await downloads.prepare(song, protecting: [song.uri])
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(
            access: IndependentAudioClient(server: address, token: "seek-fixture"),
            store: downloads.store
        )
        player.insert([song], option: "replace")
        for _ in 0 ..< 100 {
            if !player.isBuffering {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await player.seek(3)
        try await Task.sleep(for: .seconds(1))
        #expect(player.error == nil)
        #expect(player.state.position > 3.4)
        player.stop(clear: true)
        try await downloads.erase()
    }

    @Test func slowArtworkDoesNotDelayPreparedAudio() async throws {
        let server = try AudioHTTPFixture(body: AudioHTTPFixture.longAudio)
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "slow-artwork-fixture")
        let song = MediaItem(media("artwork").raw.merging([
            "duration": .number(12), "image": .object(["path": .string(address.endpoint("art.jpg").absoluteString)]),
        ]))
        let started = ContinuousClock.now
        let file = try await downloads.prepare(song, protecting: [song.uri])
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        for _ in 0 ..< 100 {
            if server.artworkRequests > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.artworkRequests == 1)
        try await downloads.erase()
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

    @Test func offlineAdvancementSkipsSongsThatRequireTheHomeServer() async throws {
        let server = try AudioHTTPFixture()
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "offline-queue-fixture")
        let first = media("saved-first"), missing = media("streaming-only"), last = media("saved-last")
        try await downloads.enqueue([first, last])
        for _ in 0 ..< 200 {
            if downloads.isDownloaded(first), downloads.isDownloaded(last) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(downloads.isDownloaded(first) && downloads.isDownloaded(last))
        server.listener.cancel()
        let player = DeviceAudioPlayer(downloads: downloads)
        await player.configure(
            access: IndependentAudioClient(server: address, token: "offline-queue-fixture"),
            store: downloads.store
        )
        player.online = false
        player.insert([first, missing, last], option: "replace")
        for _ in 0 ..< 100 {
            if player.state.current?.media.uri == last.uri {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.state.current?.media.uri == last.uri)
        for _ in 0 ..< 100 {
            if !player.wantsPlayback {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!player.wantsPlayback)
        #expect(player.error == nil)
        player.stop(clear: true)
        await player.flushPersistence()
        try await downloads.erase()
    }

    @Test func rapidNetworkPreferenceChangesSerializeBackgroundSessionReplacement() async throws {
        let server = try AudioHTTPFixture()
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "preferences-fixture")
        let original = downloads.allowCellular
        downloads.allowCellular = !original
        downloads.allowCellular = original
        downloads.allowCellular = !original
        let song = media("network-preferences")
        try await downloads.enqueue([song])
        for _ in 0 ..< 200 {
            if downloads.isDownloaded(song) || downloads.jobs.first?.state == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(downloads.isDownloaded(song))
        try await downloads.erase()
        downloads.allowCellular = original
    }
}

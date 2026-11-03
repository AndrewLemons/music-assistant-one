import AVFoundation
import Foundation
import MusicAssistantCore
import Network
import Testing

/// A real loopback endpoint exercises background delivery and FLAC-in-MP4 decoding.
private final class AudioFixtureResources: NSObject {}

private final class AudioHTTPFixture: @unchecked Sendable {
    static let legacyAudio =
        Data(
            base64Encoded: "ZkxhQwAAACIQABAAAAAOAAAQCsRC8AAArETSsSAZkBm2OdWn4rNGPpyXhAAAKCAAAAByZWZlcmVuY2UgbGliRkxBQyAxLjUuMCAyMDI1MDIxMQAAAAD/+MkYAMIAAAAAAAC47v/4yRgBxQAAAAAAAC+b//jJGALMAAAAAAAAFgH/+MkYA8sAAAAAAACBdP/4yRgE3gAAAAAAAGU1//jJGAXZAAAAAAAA8kD/+MkYBtAAAAAAAADL2v/4yRgH1wAAAAAAAFyv//jJGAj6AAAAAAAAg13/+MkYCf0AAAAAAAAUKP/4eRgKDEOzAAAAAAAA4sk="
        )!
    static let audio =
        Data(
            base64Encoded: "AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAwBtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAD6AABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACK3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAD6AAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAA+gAAAAAAAEAAAAAAaNtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAKxEAACsRFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAFObWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAESc3RibAAAAHpzdHNkAAAAAAAAAAEAAABqZkxhQwAAAAAAAAABAAAAAAAAAAAAAgAQAAAAAKxEAAAAAAAyZGZMYQAAAACAAAAiEAAQAAAADgAAEArEQvAAAKxE0rEgGZAZtjnVp+KzRj6clwAAABRidHJ0AAAAAAAABOAAAATgAAAAIHN0dHMAAAAAAAAAAgAAAAoAABAAAAAAAQAADEQAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAsAAAABAAAAQHN0c3oAAAAAAAAAAAAAAAsAAAAOAAAADgAAAA4AAAAOAAAADgAAAA4AAAAOAAAADgAAAA4AAAAOAAAAEAAAABRzdGNvAAAAAAAAAAEAAAMsAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2MS43LjEwMAAAAAhmcmVlAAAApG1kYXT/+MkYAMIAAAAAAAC47v/4yRgBxQAAAAAAAC+b//jJGALMAAAAAAAAFgH/+MkYA8sAAAAAAACBdP/4yRgE3gAAAAAAAGU1//jJGAXZAAAAAAAA8kD/+MkYBtAAAAAAAADL2v/4yRgH1wAAAAAAAFyv//jJGAj6AAAAAAAAg13/+MkYCf0AAAAAAAAUKP/4eRgKDEOzAAAAAAAA4sk="
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
            let audio = request.contains(".m4a")
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
                Data("{\"ready\":true,\"path\":\"one/v1/audio/\(UUID().uuidString).m4a\"}".utf8)
            let type = audio ? "audio/mp4" : "application/json"
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

    @Test func cancelledHandoffCannotRemoveANewerReplacement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try AudioHTTPFixture.longAudio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = try AudioHTTPFixture(body: AudioHTTPFixture.longAudio)
        let address = try await server.start()
        server.holdFiles()
        let remote = address.endpoint("one/v1/file.m4a").appending(queryItems: [.init(
            name: "uri",
            value: "library://track/handoff"
        )])
        var resolutions: [CheckedContinuation<ResolvedAudio, Never>] = []
        let queue = AVQueuePlayer()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        let player = DeviceAudioPlayer(downloads: downloads, player: queue) { _ in
            await withCheckedContinuation { resolutions.append($0) }
        }
        player.online = true
        let song = MediaItem(media("handoff").raw.merging(["duration": .number(12)]))
        player.adopt([song], index: 0, position: 0, playing: false)
        let entry = try #require(player.state.current)
        let original = AVPlayerItem(url: url)
        queue.insert(original, after: nil)
        let first = Task { await player.handOff(original, entry: entry, at: 2) }
        for _ in 0 ..< 500 where resolutions.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(resolutions.count == 1)
        first.cancel()
        let second = Task { await player.handOff(original, entry: entry, at: 4) }
        for _ in 0 ..< 500 where resolutions.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(resolutions.count == 2)
        resolutions[1].resume(returning: ResolvedAudio(url: remote, isProgressive: false))
        // Resume A while B's replacement is in the queue and its native seek is suspended.
        for _ in 0 ..< 500 where queue.items().count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(queue.items().count == 2)
        let replacement = try #require(queue.items().last)
        resolutions[0].resume(returning: ResolvedAudio(url: url, isProgressive: false))
        server.releaseFiles()
        await first.value
        await second.value
        #expect(queue.currentItem === replacement)
        #expect(queue.currentItem != nil)
        player.stop(clear: true)
    }

    @Test(arguments: [0.0, 0.05, 0.49])
    func seekingToTheEndAdvancesWithoutWaitingForImpossibleLead(_ remaining: Double) async {
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        let player = DeviceAudioPlayer(downloads: downloads)
        player.online = true
        let songs = ["first", "second"].map {
            MediaItem(media($0).raw.merging(["duration": .number(12)]))
        }
        for mode in ["off", "one", "all"] {
            player.adopt(songs, index: mode == "all" ? 1 : 0, position: 0, playing: false)
            player.setRepeat(mode)
            await player.seek(12 - remaining)
            #expect(player.state.current?.media.name == (mode == "off" ? "second" : "first"))
            #expect(player.state.position == 0)
            #expect(player.error == nil)
            player.stop(clear: true)
        }
        player.online = true
        player.adopt([songs[0]], index: 0, position: 0, playing: false)
        await player.seek(12)
        #expect(!player.wantsPlayback)
        #expect(player.state.position == 0)
        player.stop(clear: true)
    }

    @Test func highEfficiencyCacheValidatesAACAndDoesNotBecomeALosslessDownload() async throws {
        let url = try #require(Bundle(for: AudioFixtureResources.self).url(
            forResource: "one-second",
            withExtension: "m4a"
        ))
        let server = try AudioHTTPFixture(body: Data(contentsOf: url))
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "aac-fixture")
        let song = media("aac")
        let file = try await downloads.prepare(song, protecting: [song.uri], format: .aac)
        #expect(file.pathExtension == "m4a")
        #expect(downloads.isAvailable(song))
        #expect(downloads.records.first?.format == .aac)
        #expect(downloads.downloaded.isEmpty)
        #expect(try await downloads.store?.file(for: song.uri, format: .flac) == nil)
        try await downloads.erase()
    }

    @Test(arguments: [true, false])
    func legacyDownloadsRemainPlayableUntilValidatedReplacement(_ valid: Bool) async throws {
        let server = try AudioHTTPFixture(body: valid ? AudioHTTPFixture.audio : AudioHTTPFixture.legacyAudio)
        server.holdFiles()
        defer { server.releaseFiles() }
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.migration." + UUID().uuidString)
        try await downloads.configure(server: address, token: "migration-fixture")
        let store = try #require(downloads.store)
        let directory = await store.directory
        let song = media("legacy")
        await downloads.close()
        let legacy = directory.appendingPathComponent("saved.flac")
        try AudioHTTPFixture.legacyAudio.write(to: legacy)
        let manifest = try JSONValue.object([
            "version": .number(1), "audio": .array([.object([
                "metadata": song.offlineMetadata, "filename": .string("saved.flac"),
                "downloaded": .bool(true), "bytes": .number(Double(AudioHTTPFixture.legacyAudio.count)),
                "lastAccess": .number(0),
            ])]), "collections": .array([]),
            "queue": JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(DevicePlaybackQueue())),
        ])
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("library.json"))
        try await downloads.configure(server: address, token: "migration-fixture")
        #expect(downloads.isDownloaded(song))
        #expect(try await downloads.file(for: song) == legacy)
        #expect(try await AVURLAsset(url: legacy).load(.duration).seconds > 0)
        #expect(downloads.jobs.count == 1)
        try await downloads.configure(server: address, token: "migration-fixture")
        #expect(downloads.jobs.count == 1)
        server.releaseFiles()
        for _ in 0 ..< 200 {
            if downloads.jobs.isEmpty || downloads.jobs.first?.state == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if valid {
            #expect(downloads.jobs.isEmpty)
            #expect(downloads.records.first?.needsContainerUpgrade == false)
            #expect(try await downloads.file(for: song)?.pathExtension == "m4a")
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
        } else {
            #expect(downloads.jobs.first?.state == .failed)
            #expect(try await downloads.file(for: song) == legacy)
            #expect(try Data(contentsOf: legacy) == AudioHTTPFixture.legacyAudio)
        }
        try await downloads.erase()
    }

    @Test func losslessCacheRejectsAACInAnOtherwiseValidMP4() async throws {
        let url = try #require(Bundle(for: AudioFixtureResources.self).url(
            forResource: "one-second",
            withExtension: "m4a"
        ))
        let server = try AudioHTTPFixture(body: Data(contentsOf: url))
        let address = try await server.start()
        let downloads = AudioDownloads(sessionIdentifier: "one.test." + UUID().uuidString)
        try await downloads.configure(server: address, token: "wrong-codec")
        await #expect(throws: (any Error).self) {
            try await downloads.prepare(media("wrong-codec"), protecting: [], format: .flac)
        }
        #expect(downloads.records.isEmpty)
        try await downloads.erase()
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
        let snapshot = player.snapshot
        #expect(player.snapshot.receivedAt == snapshot.receivedAt)
        #expect(player.snapshot.elapsed() >= snapshot.elapsed(at: snapshot.receivedAt))
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
        let snapshot = player.snapshot
        #expect(snapshot.elapsed(at: snapshot.receivedAt.addingTimeInterval(10)) == 42)
        let clock = PlaybackClock()
        #expect(clock.value(snapshot, at: .now) == 42)
        await player.seek(41)
        #expect(clock.value(player.snapshot, at: .now) == 41)
        #expect(player.snapshot.positionChange != snapshot.positionChange)
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

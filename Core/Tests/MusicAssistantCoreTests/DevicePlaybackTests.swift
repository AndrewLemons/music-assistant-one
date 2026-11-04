import Foundation
@testable import MusicAssistantCore
import Testing

private func song(_ id: String) -> MediaItem {
    MediaItem(.object(["uri": .string("library://track/" + id), "name": .string(id), "duration": .number(180)]))
}

@Test func localQueuePreservesOccurrencesAndInsertionIntent() throws {
    var queue = DevicePlaybackQueue()
    queue.insert([song("A"), song("B"), song("A")])
    let playing = queue.currentID
    queue.insert([song("C"), song("D")], option: "next")
    queue.insert([song("E")], option: "add")
    #expect(queue.currentID == playing)
    #expect(queue.entries.map(\.media.name) == ["A", "C", "D", "B", "A", "E"])
    #expect(Set(queue.entries.map(\.id)).count == 6)
    let moved = queue.move(queue.entries[4].id, shift: -3)
    #expect(moved)
    let movedCurrent = try queue.move(#require(playing), shift: 1)
    #expect(!movedCurrent)
    #expect(queue.entries.map(\.media.name) == ["A", "A", "C", "D", "B", "E"])
    try queue.remove(#require(playing))
    #expect(queue.entries.count == 6)
}

@Test func localQueueRepeatSeekingAndPreviousFollowMusicPlayerConventions() {
    var queue = DevicePlaybackQueue()
    queue.insert([song("A"), song("B")])
    queue.seek(900); #expect(queue.position == 180)
    queue.seek(.nan); #expect(queue.position == 180)
    queue.setRepeat("one")
    let repeated = queue.advance(automatically: true)
    #expect(repeated)
    #expect(queue.current?.media.name == "A")
    let advanced = queue.advance()
    #expect(advanced)
    #expect(queue.current?.media.name == "B")
    queue.seek(10); queue.previous()
    #expect(queue.current?.media.name == "B" && queue.position == 0)
    queue.previous(); #expect(queue.current?.media.name == "A")
    queue.setRepeat("all"); _ = queue.advance(); _ = queue.advance()
    #expect(queue.current?.media.name == "A")
}

@Test func localQueueRestoresOrderAndPersistsOnlyDisplayMetadata() throws {
    var queue = DevicePlaybackQueue()
    queue.insert([song("A"), song("B"), song("C"), song("D")])
    let current = queue.currentID
    queue.setShuffle(true)
    #expect(queue.currentID == current)
    queue.setShuffle(false)
    #expect(queue.entries.map(\.media.name) == ["A", "B", "C", "D"])
    queue.seek(67)
    queue.insert([MediaItem(song("secret").raw.merging(["streamdetails": .string("private-token")]))], option: "add")
    let encoded = try JSONEncoder().encode(queue)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("private-token"))
    let restored = try JSONDecoder().decode(DevicePlaybackQueue.self, from: encoded)
    #expect(restored == queue)
    #expect(restored.snapshot(playing: false).elapsed() == 67)
}

@Test func audioStorageProtectsDownloadsAndReconcilesPurgedCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("downloads")
    let cache = root.appendingPathComponent("cache")
    let store = try AudioFileStore(directory: library, cacheDirectory: cache)
    for (id, pinned) in [("A", true), ("B", false), ("C", false)] {
        let temporary = root.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 100).write(to: temporary)
        try await store.commit(temporary, media: song(id), downloaded: pinned)
    }
    try await store.keepDownload(song("B").uri)
    try await store.trimCache(limit: 0)
    #expect(await store.records().count == 2)
    #expect(try await store.file(for: song("A").uri) != nil)
    #expect(try await store.file(for: song("B").uri) != nil)
    #expect(try await store.file(for: song("C").uri) == nil)
    var queue = DevicePlaybackQueue(); queue.insert([song("A")]); queue.seek(43)
    try await store.saveQueue(queue)
    let restored = try AudioFileStore(directory: library, cacheDirectory: cache)
    #expect(await restored.queue() == queue)
    #expect(await restored.records().allSatisfy(\.downloaded))
    let record = try #require(await restored.records().first)
    try FileManager.default.removeItem(at: library.appendingPathComponent(record.filename))
    let reconciled = try AudioFileStore(directory: library, cacheDirectory: cache)
    #expect(await reconciled.records().count == 1)
}

@Test func audioScopesSeparateServerAndAccount() throws {
    let server = try ServerAddress("https://music.example.com/prefix")
    #expect(AudioFileStore.scope(server: server, account: "one") != AudioFileStore.scope(
        server: server,
        account: "two"
    ))
    #expect(AudioFileStore.scope(server: server, account: "one").count == 64)
    let request = try IndependentAudioClient(server: server, token: "example-token").audioRequest(for: song("A & B"))
    #expect(request.url?.path == "/prefix/one/v1/file.m4a")
    #expect(try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?
        .value == song("A & B").uri)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer example-token")
    #expect(try !#require(request.url?.absoluteString.contains("example-token")))
}

@Test func offlineArtworkPersistsWithAudioAndExcludesURLCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AudioFileStore(
        directory: root.appendingPathComponent("library"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    let media = MediaItem(song("art").raw.merging(["image": .object([
        "path": .string("https://example.com/art.jpg?token=private-credential"),
    ])]))
    let metadata = try JSONEncoder().encode(media.offlineMetadata)
    #expect(!String(decoding: metadata, as: UTF8.self).contains("private-credential"))
    let audio = root.appendingPathComponent("temporary")
    try Data([1, 2, 3]).write(to: audio)
    try await store.commit(audio, media: media, downloaded: true)
    try await store.saveArtwork(Data([4, 5, 6]), for: media.uri)
    let urls = await store.artworkURLs()
    let image = try #require(urls[media.uri])
    #expect(try Data(contentsOf: image) == Data([4, 5, 6]))
    try await store.remove(media.uri)
    #expect(await store.artworkURLs().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: image.path))
}

@Test func trackSummariesUseAlbumArtworkForOfflinePresentation() {
    let track = MediaItem(song("summary").raw.merging(["track_album": .object([
        "images": .array([.object(["type": .string("thumb"), "path": .string("https://example.com/album.jpg")])]),
    ])]))
    #expect(track.artworkURL(server: nil)?.absoluteString == "https://example.com/album.jpg")
}

@Test func choosingASongPlaysItsCollectionFromThere() {
    var queue = DevicePlaybackQueue()
    queue.insert([song("A"), song("B"), song("C")], start: 1)
    #expect(queue.current?.media.name == "B")
    #expect(queue.upcoming.map(\.media.name) == ["C"])
    queue.previous()
    #expect(queue.current?.media.name == "A")
    // With shuffle, the chosen song still plays first.
    var shuffled = DevicePlaybackQueue()
    shuffled.setShuffle(true)
    shuffled.insert((0 ..< 20).map { song("S\($0)") }, start: 7)
    #expect(shuffled.current?.media.name == "S7")
    #expect(shuffled.entries.count == 20)
}

@Test func audioEncodingsHaveSeparateFilesAndLosslessDownloadsStayPinned() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AudioFileStore(
        directory: root.appendingPathComponent("library"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    for format in [AudioEncoding.flac, .aac] {
        let temporary = root.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: temporary)
        try await store.commit(temporary, media: song("formats"), downloaded: format == .flac, format: format)
    }
    #expect(await store.records().count == 2)
    let flac = try #require(await store.file(for: song("formats").uri, format: .flac))
    let aac = try #require(await store.file(for: song("formats").uri, format: .aac))
    #expect(flac.pathExtension == "m4a" && aac.pathExtension == "m4a")
    try await store.trimCache(limit: 0, protecting: [song("formats").uri])
    #expect(await store.records().count == 2)
    try await store.trimCache(limit: 0)
    #expect(await store.records().count == 1)
    #expect(FileManager.default.fileExists(atPath: flac.path))
    #expect(!FileManager.default.fileExists(atPath: aac.path))
}

@Test func lookAheadIsBoundedAndFollowsRepeatOrder() {
    var queue = DevicePlaybackQueue()
    queue.insert([song("A"), song("B"), song("C")], start: 2)
    #expect(queue.lookAhead(limit: 3).isEmpty)
    queue.setRepeat("all")
    #expect(queue.lookAhead(limit: 2).map(\.media.name) == ["A", "B"])
    queue.setRepeat("one")
    #expect(queue.lookAhead(limit: 3).map(\.media.name) == ["C"])
    #expect(queue.lookAhead(limit: 0).isEmpty)
}

@Test func listeningCacheEvictionRemovesOnlyUnreferencedArtwork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AudioFileStore(
        directory: root.appendingPathComponent("library"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    for id in ["evicted", "variant", "collection"] {
        let temporary = root.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: temporary)
        try await store.commit(temporary, media: song(id), downloaded: false, format: .aac)
        try await store.saveArtwork(Data([4, 5, 6]), for: song(id).uri)
    }
    let pinned = root.appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3]).write(to: pinned)
    try await store.commit(pinned, media: song("variant"), downloaded: true)
    try await store.saveCollection(SavedCollection(item: song("album"), tracks: [song("collection")]))
    let before = await store.artworkURLs()
    try await store.trimCache(limit: 0)
    let after = await store.artworkURLs()
    #expect(after[song("evicted").uri] == nil)
    #expect(try !FileManager.default.fileExists(atPath: #require(before[song("evicted").uri]).path))
    for id in ["variant", "collection"] {
        #expect(after[song(id).uri] == before[song(id).uri])
        #expect(try FileManager.default.fileExists(atPath: #require(before[song(id).uri]).path))
    }
    let restored = try AudioFileStore(
        directory: root.appendingPathComponent("library"),
        cacheDirectory: root.appendingPathComponent("cache")
    )
    #expect(await restored.artworkURLs() == after)
}

@Test func legacyCacheIsInvalidatedAndDownloadsSurviveUntilReplacementCommits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("library")
    let cache = root.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let legacy = library.appendingPathComponent("saved.flac")
    try Data("fLaC-original".utf8).write(to: legacy)
    try Data("fLaC-cache".utf8).write(to: cache.appendingPathComponent("cached.flac"))
    let records: [JSONValue] = [("saved", true), ("cached", false)].map { id, downloaded in
        .object([
            "metadata": song(id).offlineMetadata, "filename": .string(id + ".flac"),
            "downloaded": .bool(downloaded), "bytes": .number(13), "lastAccess": .number(0),
        ])
    }
    let manifest = library.appendingPathComponent("library.json")
    try JSONEncoder().encode(JSONValue.object([
        "version": .number(1), "audio": .array(records), "collections": .array([]),
        "queue": JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(DevicePlaybackQueue())),
    ])).write(to: manifest)
    let store = try AudioFileStore(directory: library, cacheDirectory: cache)
    #expect(await store.records().count == 1)
    #expect(await store.records().first?.needsContainerUpgrade == true)
    #expect(try await store.file(for: song("saved").uri) == legacy)
    #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("cached.flac").path))
    let restored = try AudioFileStore(directory: library, cacheDirectory: cache)
    #expect(await restored.records().map(\.filename) == store.records().map(\.filename))

    // Even a publication failure after moving the new file preserves the original manifest/file.
    let savedManifest = try Data(contentsOf: manifest)
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    let replacement = root.appendingPathComponent("replacement")
    try Data("new-mp4".utf8).write(to: replacement)
    await #expect(throws: (any Error).self) {
        try await store.commit(replacement, media: song("saved"), downloaded: true)
    }
    #expect(try Data(contentsOf: legacy) == Data("fLaC-original".utf8))
    #expect(try await store.file(for: song("saved").uri) == legacy)
    try FileManager.default.removeItem(at: manifest)
    try savedManifest.write(to: manifest)
    try Data("validated-mp4".utf8).write(to: replacement)
    let record = try await store.commit(replacement, media: song("saved"), downloaded: true)
    #expect(record.downloaded && record.format == .flac && !record.needsContainerUpgrade)
    #expect(record.filename.hasSuffix(".m4a"))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    let final = try AudioFileStore(directory: library, cacheDirectory: cache)
    #expect(await final.records() == [record])
}

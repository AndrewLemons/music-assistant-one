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
    #expect(request.url?.path == "/prefix/one/v1/file.flac")
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

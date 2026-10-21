import AVFoundation
import Foundation
import ImageIO
import MusicAssistantCore
import Observation

struct AudioDownload: Codable, Identifiable {
    enum State: String, Codable { case queued, downloading, paused, failed }
    let id: UUID
    let metadata: JSONValue
    var state: State = .queued
    var failure: String?
    var media: MediaItem {
        MediaItem(metadata)
    }
}

/// One background session for explicit downloads; speculative caching is cancellable
/// and respects Low Data Mode. Only complete, validated audio becomes playable offline.
@MainActor @Observable
final class AudioDownloads: NSObject {
    static let shared = AudioDownloads()
    static let sessionIdentifier = "com.lemonyclick.music-assistant-one.audio-downloads"
    private let backgroundSessionIdentifier: String
    private(set) var records: [StoredAudio] = []
    private(set) var jobs: [AudioDownload] = []
    private(set) var progress: [UUID: Double] = [:]
    private(set) var collections: [SavedCollection] = []
    private(set) var artworkURLs: [String: URL] = [:]
    private(set) var store: AudioFileStore?
    private(set) var scope: String?
    private var access: IndependentAudioClient?
    private var jobsURL: URL?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var cacheTasks: [String: Task<URL, any Error>] = [:]
    private var backgroundCompletion: (() -> Void)?
    private var finishing = 0
    private var backgroundEventsFinished = false
    private var sessionRevision = UUID()
    private var sessionReplacementTask: Task<Void, Never>?
    private var invalidationWaiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    var error: String?
    var onChange: (() -> Void)?
    var allowCellular = UserDefaults.standard.bool(forKey: "downloadOverCellular") {
        didSet {
            guard allowCellular != oldValue else { return }
            UserDefaults.standard.set(allowCellular, forKey: "downloadOverCellular")
            for task in tasks.values {
                task.cancel()
            }
            tasks = [:]
            for index in jobs.indices where jobs[index].state == .downloading {
                jobs[index].state = .queued
            }
            persistJobs()
            let old = session
            session = nil
            let revision = UUID(); sessionRevision = revision
            let previous = sessionReplacementTask
            sessionReplacementTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                if let old {
                    await invalidate(old)
                }
                guard sessionRevision == revision, store != nil else { return }
                session = makeSession(); resumeQueued()
            }
        }
    }

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private lazy var cacheSession = Self.makeCacheSession(expensive: false)
    @ObservationIgnored private lazy var expensiveCacheSession = Self.makeCacheSession(expensive: true)

    /// Speculative transfers never use Low Data Mode. The server may hold a request until a
    /// realtime provider finishes the song, so timeouts follow song length rather than bytes.
    private static func makeCacheSession(expensive: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = expensive
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 15 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }

    override convenience init() {
        self.init(sessionIdentifier: Self.sessionIdentifier)
    }

    init(sessionIdentifier: String) {
        backgroundSessionIdentifier = sessionIdentifier
        super.init()
    }

    var downloaded: [StoredAudio] {
        records.filter(\.downloaded)
            .sorted { $0.media.name.localizedStandardCompare($1.media.name) == .orderedAscending }
    }

    var downloadBytes: Int64 {
        downloaded.reduce(0) { $0 + $1.bytes }
    }

    var cacheBytes: Int64 {
        records.filter { !$0.downloaded }.reduce(0) { $0 + $1.bytes }
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        records.contains { $0.id == item.uri && $0.downloaded }
    }

    func isAvailable(_ item: MediaItem) -> Bool {
        records.contains { $0.id == item.uri }
    }

    func job(for item: MediaItem) -> AudioDownload? {
        jobs.first { $0.media.uri == item.uri }
    }

    func configure(server: ServerAddress, token: String) async throws {
        // A token fingerprint isolates accounts without writing authentication material to disk.
        let scope = AudioFileStore.scope(server: server, account: token)
        access = IndependentAudioClient(server: server, token: token)
        guard self.scope != scope else { return }
        await close()
        access = IndependentAudioClient(server: server, token: token)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cache = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("MusicAssistantOne/Audio/" + scope)
        store = try AudioFileStore(
            directory: directory,
            cacheDirectory: cache.appendingPathComponent("MusicAssistantOne/Audio/" + scope)
        )
        self.scope = scope
        jobsURL = directory.appendingPathComponent("downloads.json")
        if let jobsURL, FileManager.default.fileExists(atPath: jobsURL.path) {
            do { jobs = try JSONDecoder().decode([AudioDownload].self, from: Data(contentsOf: jobsURL)) }
            catch {
                jobs = []
                self.error = "Couldn’t restore pending downloads. Completed downloads are unaffected."
            }
        }
        await refresh()
        session = makeSession()
        let active = await session.allTasks
        guard self.scope == scope else { return }
        for task in active {
            guard let id = jobID(task.taskDescription), jobs.contains(where: { $0.id == id }),
                  let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
            tasks[id] = download
        }
        for index in jobs.indices where jobs[index].state == .downloading && tasks[jobs[index].id] == nil {
            jobs[index].state = .queued
        }
        persistJobs(); resumeQueued()
    }

    func close() async {
        sessionRevision = UUID()
        scope = nil
        await sessionReplacementTask?.value
        sessionReplacementTask = nil
        for task in cacheTasks.values {
            task.cancel()
        }; cacheTasks = [:]
        let old = session; session = nil
        if let old {
            let active = await old.allTasks
            active.forEach { $0.cancel() }
            await invalidate(old)
        }
        store = nil; access = nil; jobsURL = nil
        jobs = []; records = []; collections = []; artworkURLs = [:]; progress = [:]; tasks = [:]
    }

    private func invalidate(_ session: URLSession) async {
        await withCheckedContinuation { continuation in
            invalidationWaiters[ObjectIdentifier(session)] = continuation
            session.invalidateAndCancel()
        }
    }

    func erase(allScopes: Bool = false) async throws {
        var directories: [URL] = []
        if allScopes {
            for kind in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
                let root = try FileManager.default.url(
                    for: kind,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                directories.append(root.appendingPathComponent("MusicAssistantOne/Audio"))
            }
        } else if let store {
            directories = await [store.directory, store.cacheDirectory]
        }
        await close()
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func refresh() async {
        guard let store else { return }
        let scope = scope
        let records = await store.records()
        let collections = await store.collections()
        let artworkURLs = await store.artworkURLs()
        guard self.scope == scope else { return }
        self.records = records; self.collections = collections
        self.artworkURLs = artworkURLs
        onChange?()
    }

    func saveCollection(_ item: MediaItem, tracks: [MediaItem]) async throws {
        try await store?.saveCollection(SavedCollection(item: item, tracks: tracks)); await refresh()
    }

    func enqueue(_ items: [MediaItem]) async throws {
        guard let store, access != nil else { throw MAError.message("Connect to your server to download music.") }
        for item in items where item.kind == "track" && item.duration > 0 {
            if try await store.file(for: item.uri) != nil {
                try await store.keepDownload(item.uri)
            } else if job(for: item) == nil {
                jobs.append(AudioDownload(id: UUID(), metadata: item.offlineMetadata))
            }
        }
        persistJobs(); await refresh(); resumeQueued()
    }

    func pause(_ job: AudioDownload) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].state = .paused
        tasks[job.id]?.suspend()
        persistJobs(); resumeQueued()
    }

    func retry(_ job: AudioDownload) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].state = .queued; jobs[index].failure = nil
        persistJobs(); resumeQueued()
    }

    func cancel(_ job: AudioDownload) {
        jobs.removeAll { $0.id == job.id }
        tasks.removeValue(forKey: job.id)?.cancel()
        progress[job.id] = nil
        persistJobs(); resumeQueued()
    }

    func remove(_ item: MediaItem) async {
        if let job = job(for: item) {
            cancel(job)
        }
        do { try await store?.remove(item.uri); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func clearCache(protecting: Set<String>) async {
        do { try await store?.trimCache(limit: 0, protecting: protecting); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func file(for item: MediaItem) async throws -> URL? {
        let file = try await store?.file(for: item.uri)
        if file == nil, isAvailable(item) {
            await refresh()
        }
        return file
    }

    /// Deduplicate speculative requests. Explicit downloads use the system background session.
    /// `allowsExpensive` permits cellular and hotspots, for the song that plays next.
    func prepare(_ item: MediaItem, protecting: Set<String>, allowsExpensive: Bool = false) async throws -> URL {
        if let file = try await file(for: item) {
            return file
        }
        if let task = cacheTasks[item.uri] {
            return try await task.value
        }
        guard let access, let store, let scope else { throw URLError(.notConnectedToInternet) }
        try checkFreeSpace(for: item)
        var request = try access.audioRequest(for: item)
        request.timeoutInterval = 15 * 60
        let session = allowsExpensive ? expensiveCacheSession : cacheSession
        let task = Task {
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            try await Self.validate(temporary, response: response, media: item)
            let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes <= AudioFileStore.defaultCacheLimit / 4 else {
                throw MAError
                    .message("This song is too large for automatic caching. Choose Download to keep it offline.")
            }
            try Task.checkCancellation()
            guard self.scope == scope else { throw CancellationError() }
            try await store.commit(temporary, media: item, downloaded: false)
            try await store.trimCache(protecting: protecting.union([item.uri]))
            guard let result = try await store.file(for: item.uri) else { throw URLError(.fileDoesNotExist) }
            await refresh()
            await cacheArtwork(item)
            return result
        }
        cacheTasks[item.uri] = task
        defer { cacheTasks[item.uri] = nil }
        return try await task.value
    }

    func cancelPreparation(except uris: Set<String>) {
        for (uri, task) in cacheTasks where !uris.contains(uri) {
            task.cancel(); cacheTasks[uri] = nil
        }
    }

    /// Whether explicit downloads may use cellular or other expensive networks. Macs have no
    /// cellular setting, so a download the user starts proceeds on any network, including a hotspot.
    var allowsExpensiveNetworks: Bool {
        #if os(macOS)
            true
        #else
            allowCellular
        #endif
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        configuration.allowsCellularAccess = allowsExpensiveNetworks
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworks
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private func resumeQueued() {
        guard let access, let session, let scope else { return }
        for index in jobs.indices
            where jobs[index].state == .queued && jobs.filter({ $0.state == .downloading }).count < 2
        {
            do {
                let job = jobs[index]
                if let task = tasks[job.id], task.state == .suspended || task.state == .running {
                    jobs[index].state = .downloading
                    persistJobs(); task.resume(); continue
                }
                try checkFreeSpace(for: job.media)
                let task = try session.downloadTask(with: access.audioRequest(for: job.media))
                task.taskDescription = scope + ":" + job.id.uuidString
                task.countOfBytesClientExpectsToReceive = Int64(job.media.duration * 44100 * 4)
                tasks[job.id] = task; jobs[index].state = .downloading
                persistJobs(); task.resume()
            } catch { jobs[index].state = .failed; jobs[index].failure = error.localizedDescription; persistJobs() }
        }
    }

    private func checkFreeSpace(for item: MediaItem) throws {
        let capacity = try FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let estimate = Int64(min(512 * 1024 * 1024, max(0, item.duration) * 44100 * 4))
        if let capacity, capacity < estimate + 128 * 1024 * 1024 {
            throw MAError
                .message(
                    "Not enough storage to download this song."
                )
        }
    }

    private func persistJobs() {
        guard let jobsURL else { return }
        do { try JSONEncoder().encode(jobs).write(to: jobsURL, options: .atomic) }
        catch { self.error = "Couldn’t save your download list. \(error.localizedDescription)" }
    }

    private func jobID(_ description: String?) -> UUID? {
        guard let description, let scope, description.hasPrefix(scope + ":") else { return nil }
        return UUID(uuidString: String(description.dropFirst(scope.count + 1)))
    }

    private static func validate(_ file: URL, response: URLResponse?, media: MediaItem) async throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MAError.message("Download failed. Check your connection.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else {
            throw MAError.message("The server returned an invalid audio file.")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard response.expectedContentLength < 0 || Int64(size) == response.expectedContentLength else {
            throw MAError.message("Download incomplete.")
        }
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        guard duration.isFinite, duration > 0,
              media.duration <= 0 || duration >= media.duration - max(3, media.duration * 0.02)
        else {
            throw MAError.message("Download incomplete.")
        }
    }

    private func completed(_ description: String?, file: URL, response: URLResponse?) async {
        finishing += 1
        defer { finishing -= 1; finishBackgroundEventsIfReady() }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let id = jobID(description), let job = jobs.first(where: { $0.id == id }),
              job.state == .downloading || job.state == .paused, let store else { return }
        let scope = scope
        do {
            try await Self.validate(file, response: response, media: job.media)
            guard self.scope == scope,
                  jobs.contains(where: { $0.id == id && ($0.state == .downloading || $0.state == .paused) })
            else { return }
            try await store.commit(file, media: job.media, downloaded: true)
            jobs.removeAll { $0.id == id }; tasks[id] = nil; progress[id] = nil
            persistJobs(); await refresh(); resumeQueued()
            await cacheArtwork(job.media)
        } catch { failed(description, message: error.localizedDescription) }
    }

    private func cacheArtwork(_ item: MediaItem) async {
        guard artworkURLs[item.uri] == nil, let url = item.artworkURL(server: access?.server, pixels: 1024),
              let store else { return }
        let scope = scope
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard scope == self.scope, (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 10 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return }
            try await store.saveArtwork(data, for: item.uri)
            artworkURLs = await store.artworkURLs()
        } catch { /* Artwork never changes a completed audio download's availability. */ }
    }

    private func failed(_ description: String?, message: String) {
        guard let id = jobID(description), let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .downloading else { return }
        jobs[index].state = .failed; jobs[index].failure = message
        tasks[id] = nil; progress[id] = nil
        persistJobs(); resumeQueued()
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) async {
        backgroundCompletion = completion
        if session == nil, let saved = UserDefaults.standard.string(forKey: "serverAddress"),
           let server = try? ServerAddress(saved), let token = try? CredentialStore.token(for: server)
        {
            do { try await configure(server: server, token: token) }
            catch { self.error = error.localizedDescription }
        }
        if session == nil {
            backgroundEventsFinished = true; finishBackgroundEventsIfReady()
        }
    }

    private func finishBackgroundEventsIfReady() {
        guard backgroundEventsFinished, finishing == 0, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil; backgroundEventsFinished = false
        completion()
    }
}

extension AudioDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession deletes its temporary file as soon as this callback returns.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        let description = downloadTask.taskDescription
        let response = downloadTask.response
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor in await self.completed(description, file: staged, response: response) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.failed(description, message: message) }
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let description = downloadTask.taskDescription
        Task { @MainActor in
            guard let id = self.jobID(description), totalBytesExpectedToWrite > 0 else { return }
            self.progress[id] = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let message = error.localizedDescription
        let description = task.taskDescription
        Task { @MainActor in self.failed(description, message: message) }
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError _: (any Error)?) {
        Task { @MainActor in
            if self.session === session {
                self.session = nil
            }
            self.invalidationWaiters.removeValue(forKey: ObjectIdentifier(session))?.resume()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task { @MainActor in self.backgroundEventsFinished = true; self.finishBackgroundEventsIfReady() }
    }
}

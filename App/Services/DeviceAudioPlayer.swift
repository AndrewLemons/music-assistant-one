import AVFoundation
import Foundation
import MusicAssistantCore
import Observation

/// The independent device transport owns audio and queue timing without a control socket.
/// Songs start from the server's progressive stream while it prepares the complete file.
/// AVQueuePlayer holds the following item; cache preparation is bounded to a few songs.
@MainActor @Observable
final class DeviceAudioPlayer {
    private(set) var state = DevicePlaybackQueue()
    private(set) var wantsPlayback = false
    private(set) var isBuffering = false {
        didSet {
            guard isBuffering != oldValue else { return }
            loadingIndicatorTask?.cancel()
            guard isBuffering else { isLoadingVisibly = false; return }
            loadingIndicatorTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, isBuffering else { return }
                isLoadingVisibly = true
            }
        }
    }

    /// Buffering that lasts long enough to show, so quick starts never flash a spinner.
    private(set) var isLoadingVisibly = false
    @ObservationIgnored private var loadingIndicatorTask: Task<Void, Never>?
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onPlaybackFailure: (() -> Void)?
    /// A song counts as listened after half its length or four minutes, as in Music Assistant.
    var onListened: ((MediaItem, Double) -> Void)?
    var online = false
    private var access: IndependentAudioClient?
    private var store: AudioFileStore?
    private let downloads: AudioDownloads
    @ObservationIgnored private var player = AVQueuePlayer()
    private var revision = UUID()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    /// A fresh item queued to continue the current song from its complete audio.
    private var handoffItem: AVPlayerItem?
    private var persistenceTask: Task<Void, Never>?
    private var itemIDs: [ObjectIdentifier: String] = [:]
    /// Growing streams can only seek within the audio that has already arrived.
    private var progressiveItems: Set<ObjectIdentifier> = []
    private var activeItemID: ObjectIdentifier?
    private var recoveries: [String: Int] = [:]
    private var listened = (entry: "", seconds: 0.0, reported: false)
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var failureObserver: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    private var lastSave = Date.distantPast

    init(downloads: AudioDownloads = .shared) {
        self.downloads = downloads
        observePlayer()
    }

    var snapshot: PlayerQueue {
        state.snapshot(playing: wantsPlayback).predicting(["playback_speed": .number(isBuffering ? 0 : 1)])
    }

    var protectedURIs: Set<String> {
        Set(([state.current].compactMap(\.self) + Array(state.upcoming.prefix(2))).map(\.media.uri))
    }

    func configure(access: IndependentAudioClient, store: AudioFileStore?) async {
        stop(clear: true)
        self.access = access; self.store = store
        if let store {
            state = await store.queue()
        }
        publish()
    }

    /// `start` selects a song within `items`, so choosing a song in an album plays the album from there.
    func insert(_ items: [MediaItem], option: String, start: Int = 0) {
        error = nil
        let hadCurrent = state.current != nil
        state.insert(items, option: option, start: start)
        if option == "replace" || !hadCurrent {
            startCurrent()
        } else {
            rebuildUpcoming()
        }
        publish(); persist()
    }

    func adopt(_ items: [MediaItem], index: Int, position: Double, playing: Bool) {
        state.insert(items)
        if state.entries.indices.contains(index) {
            _ = state.select(state.entries[index].id)
        }
        state.seek(position)
        if playing {
            startCurrent()
        } else {
            wantsPlayback = false
        }
        publish(); persist()
    }

    func play() {
        error = nil
        guard state.current != nil else { return }
        do { try activateSession() } catch { fail(error.localizedDescription); return }
        wantsPlayback = true
        if player.currentItem == nil || player.currentItem?.status == .failed {
            if let current = state.current, state.position >= current.media.duration - 0.5 {
                state.seek(0)
            }
            startCurrent()
        } else {
            player.play(); publish()
        }
    }

    func pause() {
        capturePosition(); wantsPlayback = false
        player.pause(); publish(); persist()
    }

    func stop(clear: Bool = false) {
        pause(); revision = UUID()
        loadTask?.cancel(); prefetchTask?.cancel(); seekTask?.cancel(); completionTask?.cancel()
        loadTask = nil; prefetchTask = nil; seekTask = nil; completionTask = nil
        failureObserver = nil
        player.removeAllItems(); itemIDs = [:]; progressiveItems = []; handoffItem = nil; isBuffering = false
        if clear {
            state = DevicePlaybackQueue(); store = nil; access = nil; error = nil
        }
        publish()
    }

    func seek(_ seconds: Double) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        state.seek(seconds)
        publish()
        guard let item = player.currentItem else { persist(); return }
        let id = state.currentID
        let position = state.position
        seekTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if let pending = handoffItem, pending !== item, let entry = state.current {
                // The current stream can no longer seek reliably; move to the complete audio now.
                await handOff(item, entry: entry, at: position)
            } else {
                await seek(item, to: position)
            }
            guard id == state.currentID else { return }
            publish(); persist()
        }
        seekTask = task
        await task.value
    }

    func next(automatically: Bool = false) {
        capturePosition()
        var skippedUnavailable = false
        var advanced = state.advance(automatically: automatically)
        // Offline queues can contain streamed songs. Skip unavailable entries once,
        // without an infinite loop under Repeat All/One.
        if !online, advanced {
            let startingID = state.currentID
            var visited = Set<String>()
            while let current = state.current, !downloads.isAvailable(current.media) {
                skippedUnavailable = true
                guard visited.insert(current.id).inserted else { advanced = false; break }
                advanced = state.advance()
                if !advanced || state.currentID == startingID {
                    advanced = false; break
                }
            }
        }
        guard advanced else {
            // The finished queue rests on its last song, ready to play it again from the start.
            state.seek(0)
            wantsPlayback = false; player.pause(); player.removeAllItems()
            if skippedUnavailable {
                error = "Connect to your server to continue, or play downloaded music."
            }
            publish(); persist(); return
        }
        startCurrent(); publish(); persist()
    }

    func previous() {
        capturePosition()
        let id = state.currentID
        state.previous()
        // Restarting the current song only rewinds; reloading it would interrupt audio.
        if id == state.currentID, player.currentItem != nil {
            Task { await seek(0) }
            return
        }
        startCurrent(); publish(); persist()
    }

    func select(_ id: String) {
        guard state.select(id) else { return }
        startCurrent(); publish(); persist()
    }

    func move(_ id: String, shift: Int) {
        if state.move(id, shift: shift) {
            rebuildUpcoming(); publish(); persist()
        }
    }

    func remove(_ id: String) {
        state.remove(id); rebuildUpcoming(); publish(); persist()
    }

    func setShuffle(_ value: Bool) {
        state.setShuffle(value); rebuildUpcoming(); publish(); persist()
    }

    func setRepeat(_ value: String) {
        state.setRepeat(value); rebuildUpcoming(); publish(); persist()
    }

    func resetAudioServices() {
        stop()
        removeObservers()
        player = AVQueuePlayer()
        observePlayer()
    }

    func flushPersistence() async {
        await persistenceTask?.value
    }

    private func startCurrent() {
        error = nil
        revision = UUID(); loadTask?.cancel(); prefetchTask?.cancel(); seekTask?.cancel(); completionTask?.cancel()
        failureObserver = nil
        player.pause(); player.removeAllItems(); itemIDs = [:]; progressiveItems = []; handoffItem = nil
        guard let entry = state.current else { return }
        wantsPlayback = true; isBuffering = true
        let attempt = revision
        publish()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try activateSession()
                let source = try await source(for: entry.media)
                try Task.checkCancellation()
                guard revision == attempt else { return }
                let item = makeItem(source, id: entry.id)
                activeItemID = ObjectIdentifier(item)
                player.insert(item, after: nil)
                let position = state.position
                if source.isProgressive {
                    // Begin now; a resumed position becomes seekable as the server delivers it.
                    if wantsPlayback {
                        player.play()
                    }
                    rebuildUpcoming()
                    watchCompletion(of: item, entry: entry)
                    await seek(item, to: position, correctingStart: true)
                    return
                }
                if position > 0 {
                    await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                }
                guard revision == attempt else { return }
                if wantsPlayback {
                    player.play()
                }
                rebuildUpcoming()
            } catch is CancellationError {}
            catch {
                if revision == attempt {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    /// Seeks once the position is available. A growing stream may still be arriving.
    private func seek(_ item: AVPlayerItem, to position: Double, correctingStart: Bool = false) async {
        let target = CMTime(seconds: position, preferredTimescale: 600)
        guard progressiveItems.contains(ObjectIdentifier(item)) else {
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        let deadline = Date.now.addingTimeInterval(90)
        while !Task.isCancelled, player.currentItem === item, Date.now < deadline {
            let ready = item.status == .readyToPlay
            let available = item.seekableTimeRanges.contains {
                let range = $0.timeRangeValue
                return range.start.seconds <= position && position <= range.end.seconds - 1
            }
            if ready, correctingStart, position < 1 {
                // The stream should open at its start; correct it if a player picks a later point.
                if abs(player.currentTime().seconds - position) > 3 {
                    await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                return
            }
            if ready, available {
                isBuffering = true; publish()
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                return
            }
            if !correctingStart {
                isBuffering = true; publish()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func source(for media: MediaItem) async throws -> ResolvedAudio {
        if let file = try await downloads.file(for: media) {
            return ResolvedAudio(url: file, isProgressive: false)
        }
        guard online, let access else {
            throw MAError.message("This song isn’t available offline.")
        }
        return try await access.resolve(media)
    }

    private func rebuildUpcoming() {
        prefetchTask?.cancel()
        // A pending handoff continues the current song, so the next song follows it.
        for item in player.items().drop(while: { $0 !== queueAnchor }).dropFirst() {
            player.remove(item); forget(item)
        }
        let next = state.repeatMode == "one" ? state.current : state.upcoming
            .first ?? (state.repeatMode == "all" ? state.entries.first : nil)
        let keep = protectedURIs
        downloads.cancelPreparation(except: keep)
        let attempt = revision
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            if let next {
                do {
                    let source = try await source(for: next.media)
                    try Task.checkCancellation()
                    guard revision == attempt, let anchor = queueAnchor else { return }
                    let item = makeItem(source, id: next.id)
                    if player.canInsert(item, after: anchor) {
                        player.insert(item, after: anchor)
                    } else {
                        forget(item)
                    }
                } catch { /* A later Play/Next provides a visible, actionable error. */ }
            }
            guard online else { return }
            // The next song is cached on any network except Low Data Mode, so a car's
            // cellular connection still changes songs without waiting. The current song
            // follows, making a replay or a dropped connection independent of the network.
            let entries = [next, state.current].compactMap(\.self) + state.upcoming.dropFirst().prefix(1)
            for (index, entry) in entries.enumerated() {
                guard !Task.isCancelled, revision == attempt else { return }
                if let file = try? await downloads.prepare(entry.media, protecting: keep, allowsExpensive: index == 0),
                   !Task.isCancelled, revision == attempt, let next, entry.media.uri == next.media.uri,
                   let anchor = queueAnchor,
                   let queued = player.items().drop(while: { $0 !== anchor }).dropFirst().first,
                   itemIDs[ObjectIdentifier(queued)] == next.id, progressiveItems.contains(ObjectIdentifier(queued)) ||
                   (queued.asset as? AVURLAsset)?.url.isFileURL == false
                {
                    player.remove(queued); forget(queued)
                    let local = makeItem(ResolvedAudio(url: file, isProgressive: false), id: next.id)
                    if player.canInsert(local, after: anchor) {
                        player.insert(local, after: anchor)
                    } else {
                        forget(local)
                    }
                }
            }
        }
    }

    private func makeItem(_ source: ResolvedAudio, id: String) -> AVPlayerItem {
        // Automatic buffering loads far ahead on good networks. A preferred duration also
        // makes AVFoundation stall a stream that completes during playback.
        let item = AVPlayerItem(url: source.url)
        itemIDs[ObjectIdentifier(item)] = id
        if source.isProgressive {
            progressiveItems.insert(ObjectIdentifier(item))
        }
        return item
    }

    private func forget(_ item: AVPlayerItem) {
        itemIDs[ObjectIdentifier(item)] = nil
        progressiveItems.remove(ObjectIdentifier(item))
    }

    private var queueAnchor: AVPlayerItem? {
        if let handoffItem, player.items().contains(handoffItem) {
            return handoffItem
        }
        return player.currentItem
    }

    /// AVFoundation stops loading a stream whose playlist completes during playback once its
    /// buffer fills, and seeks on it can hang. When the server finishes the song, a fresh item
    /// of the complete audio takes over. Streams that were complete when they opened load normally.
    private func watchCompletion(of item: AVPlayerItem, entry: DevicePlaybackQueue.Entry) {
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            var growing = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, player.currentItem === item else { return }
                guard item.status == .readyToPlay else { continue }
                guard item.duration.isNumeric else { growing = true; continue }
                if growing {
                    await handOff(item, entry: entry, at: nil)
                }
                return
            }
        }
    }

    /// Continues the current song from a fresh item of its complete audio. With a position,
    /// playback moves there now; otherwise the fresh item takes over seamlessly a few seconds
    /// ahead, at a point the current item has already buffered.
    private func handOff(_ item: AVPlayerItem, entry: DevicePlaybackQueue.Entry, at position: Double?) async {
        let attempt = revision
        guard let source = try? await source(for: entry.media), revision == attempt,
              player.currentItem === item, state.currentID == entry.id else { return }
        if let pending = handoffItem {
            handoffItem = nil
            item.forwardPlaybackEndTime = .invalid
            player.remove(pending); forget(pending)
        }
        let now = player.currentTime().seconds
        let buffered = item.loadedTimeRanges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }.max() ?? 0
        let ahead = (now + 3).rounded(.up)
        let immediate = position != nil || !now.isFinite || ahead > buffered - 0.5
        let start = position ?? (immediate ? max(now.isFinite ? now : 0, 0) : ahead)
        let fresh = makeItem(ResolvedAudio(url: source.url, isProgressive: false), id: entry.id)
        guard player.canInsert(fresh, after: item) else { forget(fresh); return }
        let target = CMTime(seconds: start, preferredTimescale: 44100)
        if start > 0 {
            fresh.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        player.insert(fresh, after: item)
        handoffItem = fresh
        if immediate {
            player.advanceToNextItem()
        } else {
            item.forwardPlaybackEndTime = target
        }
    }

    /// Restarts the current song where it left off: from downloaded or cached audio when
    /// available, otherwise from a fresh server stream. Repeated failures stop playback.
    private func recover() {
        guard let entry = state.current, wantsPlayback else { return }
        capturePosition()
        let attempts = recoveries[entry.id, default: 0]
        guard attempts < 2, online || downloads.isAvailable(entry.media) else {
            fail(online ? "Couldn’t play this song. Check your connection." :
                "Connect to your server to continue, or play downloaded music.")
            return
        }
        recoveries[entry.id] = attempts + 1
        startCurrent(); publish()
    }

    private func observePlayer() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.currentItemChanged() }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isBuffering = wantsPlayback && player.timeControlStatus != .playing
                publish()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, player.currentItem != nil else { return }
                capturePosition(); recordListening(); publish()
                if Date.now.timeIntervalSince(lastSave) >= 5 {
                    persist()
                }
            }
        }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                Task { @MainActor [weak self] in
                    guard let self, wantsPlayback, itemIDs[ObjectIdentifier(item)] == state.currentID else { return }
                    // AVQueuePlayer can post the end notification before clearing its
                    // last currentItem. If a successor exists, its KVO transition owns
                    // advancement; otherwise advance here regardless of that ordering.
                    if !player.items().contains(where: { $0 !== item }) {
                        state.seek(state.current?.media.duration ?? state.position)
                        next(automatically: true)
                    }
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                Task { @MainActor [weak self] in
                    guard let self, player.currentItem === item else { return }
                    recover()
                }
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) {
                [weak self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                Task { @MainActor [weak self] in
                    // Network audio stalled, but this song finished caching: continue from the
                    // file. A stream that completed during playback won't resume on its own.
                    guard let self, player.currentItem === item, let entry = state.current,
                          (item.asset as? AVURLAsset)?.url.isFileURL == false,
                          downloads.isAvailable(entry.media) ||
                          progressiveItems.contains(ObjectIdentifier(item)) && item.duration.isNumeric
                    else { return }
                    recover()
                }
            },
        ]
    }

    private func currentItemChanged() {
        guard let item = player.currentItem, let id = itemIDs[ObjectIdentifier(item)] else { return }
        if activeItemID != ObjectIdentifier(item) {
            activeItemID = ObjectIdentifier(item)
            if item === handoffItem {
                // The same song continues from its complete audio.
                handoffItem = nil
            } else {
                _ = state.select(id)
                rebuildUpcoming(); persist()
                if progressiveItems.contains(ObjectIdentifier(item)), let entry = state.current {
                    watchCompletion(of: item, entry: entry)
                }
            }
        }
        failureObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in
                guard let self, player.currentItem === item, failed else { return }
                recover()
            }
        }
        publish()
    }

    private func recordListening() {
        guard let entry = state.current, player.rate > 0 else { return }
        if listened.entry != entry.id {
            listened = (entry.id, 0, false)
            recoveries = recoveries.filter { $0.key == entry.id }
        }
        listened.seconds += 0.5
        let duration = entry.media.duration
        if !listened.reported, duration > 0, listened.seconds >= min(duration / 2, 240) {
            listened.reported = true
            onListened?(entry.media, listened.seconds)
        }
    }

    private func capturePosition() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, player.currentItem != nil, seekTask == nil || seekTask?.isCancelled == true {
            state.seek(seconds)
        }
    }

    private func activateSession() throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        #endif
    }

    private func fail(_ message: String) {
        pause(); isBuffering = false; error = message; publish(); onPlaybackFailure?()
    }

    private func publish() {
        onChange?()
    }

    private func persist() {
        let value = state
        let store = store
        lastSave = .now
        // Chain writes, so an older snapshot cannot overwrite a later queue edit.
        let previous = persistenceTask
        persistenceTask = Task { [weak self] in
            await previous?.value
            do { try await store?.saveQueue(value) }
            catch { self?.error = "Couldn’t save your queue. \(error.localizedDescription)" }
        }
    }

    private func removeObservers() {
        itemObserver = nil; statusObserver = nil; failureObserver = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }; timeObserver = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
    }

    isolated deinit {
        removeObservers(); loadTask?.cancel(); prefetchTask?.cancel(); seekTask?.cancel(); completionTask?.cancel()
    }
}

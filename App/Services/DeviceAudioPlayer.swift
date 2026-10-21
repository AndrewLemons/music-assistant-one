import AVFoundation
import Foundation
import MusicAssistantCore
import Observation

/// The independent device transport owns audio and queue timing without a control socket.
/// AVQueuePlayer prepares the following item; cache preparation is bounded to two songs.
@MainActor @Observable
final class DeviceAudioPlayer {
    private(set) var state = DevicePlaybackQueue()
    private(set) var wantsPlayback = false
    private(set) var isBuffering = false
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onPlaybackFailure: (() -> Void)?
    var online = false
    private var access: IndependentAudioClient?
    private var store: AudioFileStore?
    private let downloads: AudioDownloads
    @ObservationIgnored private var player = AVQueuePlayer()
    private var revision = UUID()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var itemIDs: [ObjectIdentifier: String] = [:]
    private var activeItemID: ObjectIdentifier?
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var failureObserver: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
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

    func insert(_ items: [MediaItem], option: String) {
        error = nil
        let hadCurrent = state.current != nil
        state.insert(items, option: option)
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
        loadTask?.cancel(); prefetchTask?.cancel()
        loadTask = nil; prefetchTask = nil
        failureObserver = nil
        player.removeAllItems(); itemIDs = [:]; isBuffering = false
        if clear {
            state = DevicePlaybackQueue(); store = nil; access = nil; error = nil
        }
        publish()
    }

    func seek(_ seconds: Double) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        state.seek(seconds)
        let id = state.currentID
        let position = state.position
        await player.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard id == state.currentID else { return }
        publish(); persist()
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
            wantsPlayback = false; player.pause(); player.removeAllItems()
            if skippedUnavailable {
                error = "Connect to your server to continue this queue, or choose downloaded music."
            }
            publish(); persist(); return
        }
        startCurrent(); publish(); persist()
    }

    func previous() {
        capturePosition(); state.previous(); startCurrent(); publish(); persist()
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
        revision = UUID(); loadTask?.cancel(); prefetchTask?.cancel()
        failureObserver = nil
        player.pause(); player.removeAllItems(); itemIDs = [:]
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

    private func source(for media: MediaItem) async throws -> URL {
        if let file = try await downloads.file(for: media) {
            return file
        }
        guard online, let access else {
            throw MAError
                .message("This song isn’t available offline. Choose downloaded music or reconnect to your server.")
        }
        return try await access.resolve(media)
    }

    private func rebuildUpcoming() {
        prefetchTask?.cancel()
        for item in player.items().dropFirst() {
            player.remove(item); itemIDs[ObjectIdentifier(item)] = nil
        }
        let next = state.repeatMode == "one" ? state.current : state.upcoming
            .first ?? (state.repeatMode == "all" ? state.entries.first : nil)
        let following = Array(state.upcoming.prefix(2))
        let keep = protectedURIs
        downloads.cancelPreparation(except: keep)
        let attempt = revision
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            if let next {
                do {
                    let source = try await source(for: next.media)
                    try Task.checkCancellation()
                    guard revision == attempt, let current = player.currentItem else { return }
                    let item = makeItem(source, id: next.id)
                    if player.canInsert(item, after: current) {
                        player.insert(item, after: current)
                    }
                } catch { /* A later Play/Next provides a visible, actionable error. */ }
            }
            guard online else { return }
            // Cache the current track too, making a later replay independent of the network.
            let entries = following + [state.current].compactMap(\.self)
            for entry in entries {
                guard !Task.isCancelled, revision == attempt else { return }
                if let file = try? await downloads.prepare(entry.media, protecting: keep),
                   !Task.isCancelled, revision == attempt, let next, entry.media.uri == next.media.uri,
                   let current = player.currentItem, let queued = player.items().dropFirst().first,
                   itemIDs[ObjectIdentifier(queued)] == next.id
                {
                    player.remove(queued); itemIDs[ObjectIdentifier(queued)] = nil
                    let local = makeItem(file, id: next.id)
                    if player.canInsert(local, after: current) {
                        player.insert(local, after: current)
                    }
                }
            }
        }
    }

    private func makeItem(_ url: URL, id: String) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 20
        itemIDs[ObjectIdentifier(item)] = id
        return item
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
                isBuffering = wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                publish()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, player.currentItem != nil else { return }
                capturePosition(); publish()
                if Date.now.timeIntervalSince(lastSave) >= 5 {
                    persist()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
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
        }
    }

    private func currentItemChanged() {
        guard let item = player.currentItem, let id = itemIDs[ObjectIdentifier(item)] else { return }
        if activeItemID != ObjectIdentifier(item) {
            activeItemID = ObjectIdentifier(item)
            _ = state.select(id)
            rebuildUpcoming(); persist()
        }
        failureObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in
                guard let self, player.currentItem === item, failed else { return }
                fail("Couldn’t play this song. Check your connection and try again, or choose downloaded music.")
            }
        }
        publish()
    }

    private func capturePosition() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, player.currentItem != nil {
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
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }; endObserver = nil
    }

    isolated deinit { removeObservers(); loadTask?.cancel(); prefetchTask?.cancel() }
}

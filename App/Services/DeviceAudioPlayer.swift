import AVFoundation
import Foundation
import MusicAssistantCore
import Observation

/// The independent device transport owns audio and queue timing without a control socket.
/// Songs start from the server's progressive stream while it prepares the complete file.
/// AVQueuePlayer holds the following item; cache preparation is bounded to a few songs.
@MainActor @Observable
final class DeviceAudioPlayer {
    private(set) var state = DevicePlaybackQueue() {
        didSet {
            if state.position != oldValue.position || state.currentID != oldValue.currentID {
                positionUpdatedAt = .now
            }
        }
    }

    private var positionUpdatedAt = Date.now
    private var seekIssuedAt: Date?
    private(set) var wantsPlayback = false
    enum StartupPhase: Equatable {
        case idle, resolving, buffering(progress: Double), playing
    }

    private(set) var startup: StartupPhase = .idle
    private(set) var isBuffering = false {
        didSet {
            guard isBuffering != oldValue else { return }
            loadingIndicatorTask?.cancel()
            guard isBuffering else { isLoadingVisibly = false; return }
            // Taps already respond on touch; a cached song starts before a spinner would read.
            loadingIndicatorTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, isBuffering else { return }
                isLoadingVisibly = true
            }
        }
    }

    /// Buffering that lasts long enough to show, so quick starts and skips never flash a spinner.
    private(set) var isLoadingVisibly = false
    @ObservationIgnored private var loadingIndicatorTask: Task<Void, Never>?

    var currentAvailableOffline: Bool {
        state.current.map { downloads.isAvailable($0.media) } ?? false
    }

    var nextAvailableOffline: Bool {
        nextEntry.map { downloads.isAvailable($0.media) } ?? false
    }

    private var leadTask: Task<Void, Never>?
    private var stallCheckTask: Task<Void, Never>?
    private var positionEstablishedAt = Date.distantPast
    private var hintTask: Task<Void, Never>?
    private var establishingPosition = false
    private var handoffPosition: (item: ObjectIdentifier, position: Double)?
    private(set) var error: String?
    var onChange: (() -> Void)?
    var onPlaybackFailure: (() -> Void)?
    /// A song counts as listened after half its length or four minutes, as in Music Assistant.
    var onListened: ((MediaItem, Double) -> Void)?
    var online = false
    private var access: IndependentAudioClient?
    private var store: AudioFileStore?
    private let downloads: AudioDownloads
    @ObservationIgnored private var player: AVQueuePlayer
    @ObservationIgnored private let resolveAudio: ((MediaItem) async throws -> ResolvedAudio)?
    private var revision = UUID()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var seekRevision = UUID()
    private var handoffRevision = UUID()
    private var upcomingRevision = UUID()
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

    init(
        downloads: AudioDownloads = .shared, player: AVQueuePlayer = AVQueuePlayer(),
        resolveAudio: ((MediaItem) async throws -> ResolvedAudio)? = nil
    ) {
        self.downloads = downloads
        self.player = player
        self.resolveAudio = resolveAudio
        observePlayer()
        downloads.onNetworkChange = { [weak self] in self?.rebuildUpcoming() }
    }

    var snapshot: PlayerQueue {
        let sample = state.snapshot(playing: wantsPlayback, at: positionUpdatedAt)
        return PlayerQueue(sample.raw, receivedAt: positionUpdatedAt, positionChange: seekIssuedAt)
            .predicting(["playback_speed": .number(isBuffering ? 0 : Double(player.rate))])
    }

    private var preparationWindow: [DevicePlaybackQueue.Entry] {
        [state.current].compactMap(\.self) + state.lookAhead(limit: downloads.isConstrained ? 1 : 3)
    }

    var protectedURIs: Set<String> {
        Set(preparationWindow.map(\.media.uri))
    }

    private var nextEntry: DevicePlaybackQueue.Entry? {
        state.lookAhead(limit: 1).first
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
    /// Without it, playback starts at the first song, or a random one with shuffle.
    func insert(_ items: [MediaItem], option: String, start: Int? = nil) {
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

    /// Continues the current list without interrupting the current or prepared song.
    func append(_ items: [MediaItem]) {
        guard !items.isEmpty, state.current != nil else { return }
        state.append(items)
        rebuildUpcoming(); publish(); persist()
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
            resumeWithLead(); publish()
        }
    }

    func pause() {
        capturePosition(); wantsPlayback = false
        player.pause(); isBuffering = false; startup = .idle; publish(); persist()
    }

    func stop(clear: Bool = false) {
        pause(); revision = UUID()
        leadTask?.cancel(); leadTask = nil; hintTask?.cancel(); hintTask = nil
        stallCheckTask?.cancel(); stallCheckTask = nil
        establishingPosition = false; handoffPosition = nil
        if let access {
            Task { try? await access.prepare([]) }
        }
        loadTask?.cancel(); prefetchTask?.cancel(); seekTask?.cancel(); completionTask?.cancel()
        loadTask = nil; prefetchTask = nil; seekTask = nil; completionTask = nil
        seekRevision = UUID(); handoffRevision = UUID(); upcomingRevision = UUID()
        player.currentItem?.cancelPendingSeeks()
        downloads.cancelPreparation(except: [])
        failureObserver = nil
        player.removeAllItems(); itemIDs = [:]; progressiveItems = []; handoffItem = nil; isBuffering = false
        if clear {
            state = DevicePlaybackQueue(); store = nil; access = nil; error = nil
        }
        publish()
    }

    func seek(_ seconds: Double) async {
        trace("seek requested target=\(seconds)")
        guard seconds.isFinite, seconds >= 0 else { return }
        stallCheckTask?.cancel(); stallCheckTask = nil
        seekIssuedAt = .now
        handoffRevision = UUID()
        state.seek(seconds)
        publish()
        guard let item = player.currentItem else { persist(); return }
        let id = state.currentID
        let position = state.position
        loadTask?.cancel(); loadTask = nil
        seekTask?.cancel()
        item.cancelPendingSeeks()
        let attempt = UUID(); seekRevision = attempt
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if seekRevision == attempt {
                    seekTask = nil
                }
            }
            if let pending = handoffItem, pending !== item, let entry = state.current {
                // The current stream can no longer seek reliably; move to the complete audio now.
                await handOff(item, entry: entry, at: position)
            } else {
                await seek(item, to: position)
            }
            trace("seek finished target=\(position) cancelled=\(Task.isCancelled) current=\(seekRevision == attempt)")
            guard !Task.isCancelled, seekRevision == attempt, id == state.currentID else { return }
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
        if !online || !downloads.isConnected, advanced {
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
            stop()
            state.seek(0)
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
        leadTask?.cancel(); leadTask = nil; establishingPosition = false; handoffPosition = nil
        revision = UUID(); loadTask?.cancel(); prefetchTask?.cancel(); seekTask?.cancel(); completionTask?.cancel()
        loadTask = nil; prefetchTask = nil; seekTask = nil; completionTask = nil
        seekRevision = UUID(); handoffRevision = UUID(); upcomingRevision = UUID()
        player.currentItem?.cancelPendingSeeks()
        failureObserver = nil
        guard let entry = state.current else { return }
        // Keep the exact AVPlayerItem that has already resolved and buffered. Recreating it
        // on Next throws that work away and puts provider/network startup back on the path.
        if state.position == 0, let prepared = player.items().first(where: {
            $0 !== player.currentItem && $0 !== handoffItem &&
                itemIDs[ObjectIdentifier($0)] == entry.id && $0.status != .failed
        }) {
            do { try activateSession() } catch { fail(error.localizedDescription); return }
            wantsPlayback = true
            activeItemID = ObjectIdentifier(prepared)
            let previous = player.items()
            for item in previous where item !== player.currentItem && item !== prepared {
                player.remove(item)
            }
            handoffItem = nil
            player.advanceToNextItem()
            for item in previous where item !== prepared {
                forget(item)
            }
            resumeWithLead()
            isBuffering = player.timeControlStatus != .playing
            if progressiveItems.contains(ObjectIdentifier(prepared)) {
                watchCompletion(of: prepared, entry: entry)
            }
            rebuildUpcoming(); publish()
            return
        }
        player.pause(); player.removeAllItems(); itemIDs = [:]; progressiveItems = []; handoffItem = nil
        activeItemID = nil
        wantsPlayback = true; isBuffering = true; startup = .resolving; establishingPosition = true
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
                rebuildUpcoming()
                if source.isProgressive {
                    watchCompletion(of: item, entry: entry)
                }
                try await establishLead(item, at: position, establishStart: true)
                guard revision == attempt else { return }
            } catch is CancellationError {}
            catch {
                if revision == attempt {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    /// A paused growing item must keep loading. Establish its exact position before
    /// making audio audible; a live-edge correction after play is an audible rewind.
    /// The playhead moves first: AVFoundation loads around the playhead, so waiting for
    /// audio at a new position before seeking there would wait forever.
    private func establishLead(_ item: AVPlayerItem, at position: Double, establishStart: Bool) async throws {
        trace("lead begin position=\(position) establishStart=\(establishStart)")
        defer { trace("lead end position=\(position)") }
        let progressive = progressiveItems.contains(ObjectIdentifier(item))
        player.pause()
        establishingPosition = true
        isBuffering = wantsPlayback
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(90))
        func checkDeadline() throws {
            // Bound startup rather than playing an unintended live-edge position on timeout.
            guard clock.now < deadline
            else { throw MAError.message("Audio is taking too long to load. Check your connection and retry.") }
        }

        if establishStart {
            // A growing stream can only seek within audio the server has already produced.
            while !Task.isCancelled, player.currentItem === item {
                guard item.status != .failed else { throw MAError.message("Couldn’t load this song. Try again.") }
                if item.status == .readyToPlay,
                   !progressive || position < 0.1 || item.seekableTimeRanges.contains(where: {
                       let range = $0.timeRangeValue
                       return range.start.seconds <= position && position <= range.end.seconds - 0.5
                   })
                {
                    break
                }
                startup = .buffering(progress: 0); isBuffering = wantsPlayback; publish()
                try checkDeadline()
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard player.currentItem === item else { return }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled {
                    item.cancelPendingSeeks()
                }
            }
            defer { timeout.cancel() }
            let success = await player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            try Task.checkCancellation()
            trace("lead seek done success=\(success)")
            guard success else { throw MAError.message("Couldn’t seek this song. Try again.") }
        }

        var first: (time: ContinuousClock.Instant, end: Double)?
        while !Task.isCancelled, player.currentItem === item {
            guard item.status != .failed else { throw MAError.message("Couldn’t load this song. Try again.") }
            let now = clock.now
            let end = contiguousEnd(item, from: position)
            if first == nil, end > position {
                first = (now, end)
            }
            var target = 5.0
            if let first {
                let elapsed = first.time.duration(to: now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                if seconds >= 0.8, (end - first.end) / seconds >= 1.7 {
                    target = 2
                }
            }
            if let duration = state.current?.media.duration, duration > position {
                target = min(target, max(0.1, duration - position - 0.1))
            }
            startup = .buffering(progress: min(1, max(0, (end - position) / target)))
            isBuffering = wantsPlayback; publish()
            if item.status == .readyToPlay, !progressive || end - position >= target {
                guard player.currentItem === item else { return }
                establishingPosition = false
                positionEstablishedAt = .now
                if wantsPlayback {
                    player.playImmediately(atRate: 1)
                }
                return
            }
            try checkDeadline()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    /// A wait right after a seek or start is AVFoundation loading the new position, not a
    /// stall. Only a wait that persists, outside that window, rebuilds the lead or recovers.
    private func scheduleStallCheck() {
        stallCheckTask?.cancel()
        stallCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            stallCheckTask = nil
            guard wantsPlayback, !establishingPosition, leadTask == nil, seekTask == nil, loadTask == nil,
                  Date.now.timeIntervalSince(positionEstablishedAt) > 2,
                  player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  player.reasonForWaitingToPlay == .toMinimizeStalls,
                  let item = player.currentItem, state.position > 0.5,
                  contiguousEnd(item, from: player.currentTime().seconds) - player.currentTime().seconds < 0.3
            else { return }
            trace("stall confirmed")
            if let entry = state.current, downloads.isAvailable(entry.media) {
                recover()
            } else {
                resumeWithLead()
            }
        }
    }

    private func trace(_ event: String) {
        guard PlaybackDiagnostics.enabled else { return }
        let item = player.currentItem
        let kind = item.map { progressiveItems.contains(ObjectIdentifier($0)) ? "hls" :
            (($0.asset as? AVURLAsset)?.url.isFileURL == true ? "file" : "net")
        } ?? "none"
        func ranges(_ values: [NSValue]?) -> String {
            (values ?? []).map { String(
                format: "%.1f-%.1f",
                $0.timeRangeValue.start.seconds,
                CMTimeRangeGetEnd($0.timeRangeValue).seconds
            ) }.joined(separator: ",")
        }
        PlaybackDiagnostics.log(
            "\(event) | entry=\(state.currentID ?? "-") pos=\(String(format: "%.2f", state.position)) " +
                "t=\(String(format: "%.2f", player.currentTime().seconds)) rate=\(player.rate) " +
                "tcs=\(player.timeControlStatus.rawValue) wait=\(player.reasonForWaitingToPlay?.rawValue ?? "-") " +
                "item=\(kind) status=\(item?.status.rawValue ?? -1) items=\(player.items().count) " +
                "handoff=\(handoffItem != nil) establishing=\(establishingPosition) wants=\(wantsPlayback) " +
                "seekTask=\(seekTask != nil) lead=\(leadTask != nil) load=\(loadTask != nil) " +
                "loaded=[\(ranges(item?.loadedTimeRanges))] seekable=[\(ranges(item?.seekableTimeRanges))]"
        )
    }

    private func contiguousEnd(_ item: AVPlayerItem, from position: Double) -> Double {
        var end = position
        for range in item.loadedTimeRanges.map(\.timeRangeValue).sorted(by: { $0.start < $1.start }) {
            if range.start.seconds <= end + 0.05, range.end.seconds > end {
                end = range.end.seconds
            }
        }
        return end
    }

    private func resumeWithLead() {
        guard leadTask == nil, !establishingPosition, let item = player.currentItem else { return }
        player.pause(); capturePosition()
        let position = state.position
        let attempt = revision
        leadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == attempt {
                    leadTask = nil
                }
            }
            do { try await establishLead(item, at: position, establishStart: true) }
            catch is CancellationError {} catch { fail(error.localizedDescription) }
        }
    }

    private func seek(_ item: AVPlayerItem, to position: Double) async {
        leadTask?.cancel(); leadTask = nil
        do { try await establishLead(item, at: position, establishStart: true) }
        catch is CancellationError {} catch { fail(error.localizedDescription) }
    }

    private func source(for media: MediaItem) async throws -> ResolvedAudio {
        if let resolveAudio {
            return try await resolveAudio(media)
        }
        if let file = try await downloads.file(for: media) {
            return ResolvedAudio(url: file, isProgressive: false)
        }
        guard online, downloads.isConnected, let access else {
            throw MAError.message("This song isn’t available offline.")
        }
        return try await access.resolve(media, format: downloads.streamingFormat)
    }

    private func rebuildUpcoming() {
        prefetchTask?.cancel(); hintTask?.cancel()
        let window = preparationWindow
        if online, downloads.isConnected, let access {
            let format = downloads.streamingFormat
            hintTask = Task {
                while !Task.isCancelled {
                    try? await access.prepare(window.map(\.media), format: format)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
        let upcomingAttempt = UUID(); upcomingRevision = upcomingAttempt
        let next = nextEntry
        // A pending handoff continues the current song, so the next song follows it.
        let queued = player.items().drop(while: { $0 !== queueAnchor }).dropFirst()
        let prepared = queued.first {
            itemIDs[ObjectIdentifier($0)] == next?.id && $0.status != .failed
        }
        for item in queued where item !== prepared {
            player.remove(item); forget(item)
        }
        let hasPreparedItem = prepared != nil
        let keep = protectedURIs
        downloads.cancelPreparation(except: keep)
        let attempt = revision
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            if let next, !hasPreparedItem {
                do {
                    let source = try await source(for: next.media)
                    try Task.checkCancellation()
                    guard revision == attempt, upcomingRevision == upcomingAttempt,
                          let anchor = queueAnchor else { return }
                    guard !source.isProgressive else { throw CancellationError() }
                    let item = makeItem(source, id: next.id)
                    if player.canInsert(item, after: anchor) {
                        player.insert(item, after: anchor)
                    } else {
                        forget(item)
                    }
                } catch { /* A later Play/Next provides a visible, actionable error. */ }
            }
            guard online, downloads.isConnected else { return }
            // Start next first, then finish the current file concurrently. Server renders
            // remain ordered current → next for single-slot providers. Later files follow.
            let current = state.current
            async let nextPrepared: Void = prepare(
                next, upcoming: true, protecting: keep, attempt: attempt, upcomingAttempt: upcomingAttempt
            )
            async let currentPrepared: Void = prepare(
                downloads.isConstrained ? nil : current, upcoming: false, protecting: keep,
                attempt: attempt, upcomingAttempt: upcomingAttempt
            )
            _ = await (nextPrepared, currentPrepared)
            for later in window.dropFirst(2) {
                guard !Task.isCancelled, revision == attempt, upcomingRevision == upcomingAttempt else { return }
                _ = try? await downloads.prepare(later.media, protecting: keep, format: downloads.streamingFormat)
            }
        }
    }

    private func prepare(
        _ entry: DevicePlaybackQueue.Entry?, upcoming: Bool, protecting keep: Set<String>,
        attempt: UUID, upcomingAttempt: UUID
    ) async {
        guard let entry, !Task.isCancelled, revision == attempt, upcomingRevision == upcomingAttempt else { return }
        guard let file = try? await downloads.prepare(
            entry.media,
            protecting: keep,
            allowsExpensive: true,
            format: downloads.streamingFormat
        ),
            !Task.isCancelled, revision == attempt, upcomingRevision == upcomingAttempt, upcoming else { return }
        replaceUpcoming(with: file, entry: entry)
    }

    private func replaceUpcoming(with file: URL, entry: DevicePlaybackQueue.Entry) {
        guard let anchor = queueAnchor,
              nextEntry?.id == entry.id else { return }
        if let queued = player.items().drop(while: { $0 !== anchor }).dropFirst().first {
            guard itemIDs[ObjectIdentifier(queued)] == entry.id,
                  (queued.asset as? AVURLAsset)?.url.isFileURL == false else { return }
            player.remove(queued); forget(queued)
        }
        let local = makeItem(ResolvedAudio(url: file, isProgressive: false), id: entry.id)
        if player.canInsert(local, after: anchor) {
            player.insert(local, after: anchor)
        } else {
            forget(local)
        }
    }

    private func makeItem(_ source: ResolvedAudio, id: String) -> AVPlayerItem {
        // Automatic buffering loads far ahead on good networks. A preferred duration also
        // makes AVFoundation stall a stream that completes during playback.
        let item = AVPlayerItem(url: source.url)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
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
                if establishingPosition {
                    continue
                }
                if growing {
                    await handOff(item, entry: entry, at: nil)
                    if handoffItem == nil, player.currentItem === item {
                        continue
                    }
                }
                return
            }
        }
    }

    /// Continues the current song from a fresh item of its complete audio. With a position,
    /// playback moves there now; otherwise the fresh item takes over seamlessly a few seconds
    /// ahead, at a point the current item has already buffered.
    func handOff(_ item: AVPlayerItem, entry: DevicePlaybackQueue.Entry, at position: Double?) async {
        trace("handoff begin at=\(position.map { String($0) } ?? "scheduled")")
        defer { trace("handoff end") }
        guard !Task.isCancelled, player.currentItem === item, state.currentID == entry.id else { return }
        let attempt = revision
        let ownership = UUID(); handoffRevision = ownership
        guard let source = try? await source(for: entry.media), !Task.isCancelled,
              !source.isProgressive, revision == attempt, handoffRevision == ownership,
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
        if immediate {
            player.pause(); capturePosition()
        }
        let start = position ?? (immediate ? state.position : ahead)
        let fresh = makeItem(ResolvedAudio(url: source.url, isProgressive: false), id: entry.id)
        guard player.canInsert(fresh, after: item) else { forget(fresh); return }
        let target = CMTime(seconds: start, preferredTimescale: 44100)
        player.insert(fresh, after: item)
        handoffItem = fresh
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled {
                fresh.cancelPendingSeeks()
            }
        }
        defer { timeout.cancel() }
        let ready = await fresh.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        guard ready, !Task.isCancelled, revision == attempt, handoffRevision == ownership,
              player.currentItem === item, state.currentID == entry.id,
              immediate || player.currentTime().seconds < start - 0.1
        else {
            // This attempt may only retire its own queued item. A newer handoff can
            // already own the queue, or natural advancement can have consumed this one.
            if handoffItem === fresh, player.currentItem !== fresh {
                handoffItem = nil
                item.forwardPlaybackEndTime = .invalid
                player.remove(fresh); forget(fresh)
            }
            return
        }
        handoffPosition = (ObjectIdentifier(fresh), start)
        if immediate {
            player.advanceToNextItem()
            if wantsPlayback {
                player.playImmediately(atRate: 1)
            }
        } else {
            item.forwardPlaybackEndTime = target
        }
    }

    /// Restarts the current song where it left off: from downloaded or cached audio when
    /// available, otherwise from a fresh server stream. Repeated failures stop playback.
    private func recover() {
        trace("recover")
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
                isBuffering = wantsPlayback && (establishingPosition || player.timeControlStatus != .playing)
                if !isBuffering, wantsPlayback {
                    startup = .playing
                }
                trace("time control changed")
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    scheduleStallCheck()
                }
                capturePosition()
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
        trace("current item changed")
        guard let item = player.currentItem, let id = itemIDs[ObjectIdentifier(item)] else { return }
        // AVQueuePlayer releases consumed items. Release their identity records as well.
        let retained = Set(player.items().map(ObjectIdentifier.init))
        itemIDs = itemIDs.filter { retained.contains($0.key) }
        progressiveItems.formIntersection(retained)
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
        guard !establishingPosition, let item = player.currentItem,
              itemIDs[ObjectIdentifier(item)] == state.currentID else { return }
        if let floor = handoffPosition, player.currentItem.map(ObjectIdentifier.init) == floor.item {
            guard seconds.isFinite, seconds >= floor.position - 0.05 else { return }
            handoffPosition = nil
        }
        if seconds.isFinite, player.currentItem != nil, seekTask == nil || seekTask?.isCancelled == true {
            state.seek(seconds)
            positionUpdatedAt = .now
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
        trace("fail \(message)")
        pause(); establishingPosition = false; isBuffering = false; error = message; publish(); onPlaybackFailure?()
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
        removeObservers(); leadTask?.cancel(); stallCheckTask?.cancel(); hintTask?.cancel(); loadTask?
            .cancel(); prefetchTask?.cancel(); seekTask?
            .cancel(); completionTask?.cancel()
    }
}

/// Opt-in playback trace for field diagnosis, enabled with the `PlaybackDiagnostics` user
/// default (for example, the `-PlaybackDiagnostics YES` launch argument). Lines go to
/// Caches/playback-diagnostics.log, capped in size, and never include credentials or URLs.
enum PlaybackDiagnostics {
    static let enabled = UserDefaults.standard.bool(forKey: "PlaybackDiagnostics")
    private static let queue = DispatchQueue(label: "one.playback-diagnostics")
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("playback-diagnostics.log")
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = formatter.string(from: .now) + " " + message() + "\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 4_000_000
            {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

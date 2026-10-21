import Foundation
import MusicAssistantCore
import Network
import Observation
#if os(iOS)
    import UIKit
#endif

@MainActor @Observable
final class AppModel {
    enum Connection: Equatable { case disconnected, connecting, connected, reconnecting }
    var connection: Connection = .disconnected {
        didSet { deviceAudio.online = connection == .connected }
    }

    var server: ServerAddress?
    var serverName = "Music Assistant"
    var serverVersion = ""
    private(set) var connectionError: String?
    var error: String?
    private var confirmedPlayers: [Player] = []
    let volumeControl = VolumeControl()
    private var selectLocalWhenReady = false
    private var resettingAudio = false
    var players: [Player] {
        get { confirmedPlayers.map { player in
            guard let volume = volumeControl.pending[player.id] else { return player }
            return Player(player.raw.merging(["group_volume": .number(volume)]))
        } }
        set { confirmedPlayers = newValue }
    }

    var selectedPlayerID: String? {
        didSet {
            guard oldValue != selectedPlayerID else { return }
            selectLocalWhenReady = false
            if !isDemo {
                UserDefaults.standard.set(selectedPlayerID, forKey: "selectedPlayerID")
            }
            queue = nil; queueItems = []; queueError = nil; queueLoading = false
            systemMedia?.update()
            selectionTask?.cancel()
            selectionTask = Task { await loadQueue() }
        }
    }

    private var confirmedQueue: PlayerQueue?
    private var predictedQueue: PlayerQueue?
    var queue: PlayerQueue? {
        get {
            if isDeviceSelected,
               usesIndependentPlayback
            {
                return deviceAudio.state.current == nil ? nil : deviceAudio.snapshot
            }
            if isDeviceSelected {
                return predictedQueue?.id == sendspinQueue?.id ? predictedQueue ?? sendspinQueue : sendspinQueue
            }
            return predictedQueue?.id == confirmedQueue?.id ? predictedQueue ?? confirmedQueue : confirmedQueue
        }
        set { confirmedQueue = newValue }
    }

    private var sendspinQueue: PlayerQueue?
    var localQueue: PlayerQueue? {
        get { usesIndependentPlayback && deviceAudio.state.current != nil ? deviceAudio.snapshot : sendspinQueue }
        set { sendspinQueue = newValue }
    }

    private var remoteQueueItems: [QueueEntry] = []
    var queueItems: [QueueEntry] {
        get {
            isDeviceSelected && usesIndependentPlayback ? deviceAudio.state.entries
                .map(\.queueEntry) : remoteQueueItems
        }
        set { remoteQueueItems = newValue }
    }

    var queueLoading = false
    var queueError: String?
    var albums: [MediaItem] = []
    var playlists: [MediaItem] = []
    var tracks: [MediaItem] = []
    var libraryLoading = false
    var libraryError: String?
    var searchText = ""
    static let searchKinds = ["track", "album", "artist", "playlist", "radio"]
    let searchPages = Dictionary(uniqueKeysWithValues: searchKinds.map { ($0, MediaPager(pageSize: 25)) })
    private var searchGeneration = UUID()
    private(set) var searchDebouncing = false
    private var libraryCacheTask: Task<Void, Never>?
    private var librarySnapshots: [String: [MediaItem]] = [:]
    var showNowPlaying = false
    var showPlayers = false
    var showConnection = false
    var commandInFlight = false
    let local = LocalPlayer()
    let deviceAudio = DeviceAudioPlayer()
    let downloads = AudioDownloads.shared
    private(set) var independentAudioAvailable = false
    private(set) var audioSupportChecked = false
    private(set) var usesIndependentPlayback = true
    private var audioSupportTask: Task<Void, Never>?
    let interruption = PlaybackInterruption()
    #if os(iOS)
        private var recoveryBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    let discovery = ServerDiscovery()
    let api = MusicAssistantClient()
    private(set) var localPlayerEnabled = UserDefaults.standard.bool(forKey: "localPlayerEnabled")
    private var localRecoveryTask: Task<Void, Never>?
    var hasSavedSession: Bool {
        server != nil && token != nil
    }

    private var token: String?
    private let networkMonitor = NWPathMonitor()
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var queueRefreshTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isDemo = false
    private var systemMedia: SystemMedia?

    var selectedPlayer: Player? {
        if isDeviceSelected {
            return Player(.object([
                "player_id": .string(DevicePlaybackQueue.playerID),
                "name": .string("This Device"),
                "available": .bool(true),
                "provider": .string("one"),
            ]))
        }
        return players.first { $0.id == selectedPlayerID }
    }

    var availablePlayers: [Player] {
        players.filter { $0.isVisiblePlaybackTarget(localPlayerID: local.clientID) }
    }

    var canControl: Bool {
        !isDemo && !commandInFlight && !queueEditing && (isDeviceSelected && usesIndependentPlayback ||
            connection == .connected && selectedPlayer?.available == true)
    }

    var current: MediaItem? {
        queue?.current
    }

    func start() async {
        guard eventTask == nil else { return }
        systemMedia = SystemMedia(model: self)
        deviceAudio.onChange = { [weak self] in self?.systemMedia?.update() }
        deviceAudio.onPlaybackFailure = { [weak self] in self?.checkAudioSupport(force: true) }
        local.shouldDeactivateAudioSession = { [weak self] in self?.deviceAudio.wantsPlayback != true }
        local.onStreamStarted = { [weak self] in
            guard let self else { return }
            deviceAudio.pause()
            usesIndependentPlayback = false
            Task { await self.loadQueue() }
        }
        local.onPlaybackFailure = { [weak self] in
            guard let self, !interruption.isInterrupted else { return }
            beginRecoveryTime()
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.deviceAudio.online = reachable && self.connection == .connected
                guard reachable, self.connection == .reconnecting else { return }
                self.retryConnection()
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "MusicAssistant.connectivity"))
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            loadDemo()
            return
        }
        eventTask = Task { [weak self, api] in
            for await event in api.events {
                guard let self else { return }
                handle(event)
            }
        }
        guard !ProcessInfo.processInfo.arguments.contains("--onboarding"),
              let saved = UserDefaults.standard.string(forKey: "serverAddress") else { return }
        do {
            let address = try ServerAddress(saved)
            if let token = try CredentialStore.token(for: address) {
                server = address; self.token = token
                selectedPlayerID = UserDefaults.standard.string(forKey: "selectedPlayerID")
                restoreLibrary()
                await configureDeviceAudio(address: address, token: token)
                do { try await connect(address: address, token: token, persist: false) }
                catch {
                    guard hasSavedSession else { return }
                    connectionError = error.localizedDescription; connection = .reconnecting; scheduleReconnect()
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func signIn(address: String, username: String, password: String, accessToken: String) async throws {
        let server = try ServerAddress(address)
        connection = .connecting
        do {
            let token = accessToken.isEmpty ? try await MusicAssistantClient.login(
                server: server,
                username: username,
                password: password
            ) : accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            try await connect(address: server, token: token, persist: true)
        } catch {
            await api.disconnect()
            connection = .disconnected
            throw error
        }
    }

    private func connect(address: ServerAddress, token: String, persist: Bool) async throws {
        connection = .connecting
        let attempt = generation
        let info = try await api.connect(server: address, token: token)
        guard attempt == generation else { throw CancellationError() }
        do {
            if persist {
                try CredentialStore.save(token, for: address)
            }
        } catch { await api.disconnect(); connection = .disconnected; throw error }
        localRecoveryTask?.cancel(); localRecoveryTask = nil
        generation = UUID()
        server = address; self.token = token
        serverName = info["name"].string ?? "Music Assistant"
        serverVersion = info["server_version"].string ?? ""
        UserDefaults.standard.set(address.baseURL.absoluteString, forKey: "serverAddress")
        connection = .connected
        connectionError = nil
        showConnection = false
        error = nil
        selectedPlayerID = UserDefaults.standard.string(forKey: "selectedPlayerID") ?? DevicePlaybackQueue.playerID
        await configureDeviceAudio(address: address, token: token)
        checkAudioSupport()
        ensureLocalPlayer()
        do { try await refreshPlayers(); await loadQueue(); await loadLibrary() }
        catch { scheduleReconnect() }
    }

    func disconnect(forget: Bool = false) async {
        generation = UUID()
        audioSupportTask?.cancel(); audioSupportTask = nil
        deviceAudio.stop(clear: true)
        await deviceAudio.flushPersistence()
        if forget {
            do { try await downloads.erase() } catch { self.error = error.localizedDescription }
        } else {
            await downloads.close()
        }
        independentAudioAvailable = false; audioSupportChecked = false
        interruption.reset()
        endRecoveryTime()
        predictedQueue = nil; volumeControl.cancel(); commandInFlight = false
        selectLocalWhenReady = false
        libraryLoading = false
        searchGeneration = UUID()
        searchDebouncing = false
        for page in searchPages.values {
            page.reset()
        }
        libraryCacheTask?.cancel(); libraryCacheTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        localRecoveryTask?.cancel(); localRecoveryTask = nil
        selectionTask?.cancel(); queueRefreshTask?.cancel()
        connection = .disconnected
        await api.disconnect()
        await local.stop()
        systemMedia?.clear()
        if forget, let server {
            do { try CredentialStore.delete(for: server) }
            catch { self.error = error.localizedDescription }
            UserDefaults.standard.removeObject(forKey: "serverAddress")
            if let key = libraryCacheKey {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        token = nil; server = nil; players = []; queue = nil; localQueue = nil; queueItems = []; selectedPlayerID = nil
        albums = []; playlists = []; tracks = []; searchText = ""
        mediaOverrides = [:]
        librarySnapshots = [:]
        isDemo = false
        showNowPlaying = false; showPlayers = false
    }

    func eraseLocalData() async throws {
        deviceAudio.stop(clear: true)
        await deviceAudio.flushPersistence()
        try await downloads.erase(allScopes: true)
        await disconnect()
        try CredentialStore.deleteAll()
        try await local.eraseStoredIdentity()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("libraryCache:") {
            defaults.removeObject(forKey: key)
        }
        downloads.allowCellular = false
        for key in ["serverAddress", "selectedPlayerID", "localPlayerEnabled", "downloadOverCellular"] {
            defaults.removeObject(forKey: key)
        }
        localPlayerEnabled = false
    }

    func refreshPlayers() async throws {
        guard !isDemo else { return }
        let epoch = generation
        let result = try await api.command("players/all")
        guard epoch == generation, connection == .connected else { return }
        players = result.array.map(Player.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        reconcileDeviceRoute()
        if selectLocalWhenReady, local.isConnected, let player = localPlaybackPlayer, player.available {
            selectedPlayerID = DevicePlaybackQueue.playerID
            selectLocalWhenReady = false
        }
        // Never silently switch playback to another room after the selected player disappears.
        if selectedPlayerID == nil, !selectLocalWhenReady {
            selectedPlayerID = DevicePlaybackQueue.playerID
        }
    }

    func loadLibrary() async {
        guard connection == .connected, !isDemo, !libraryLoading else { return }
        libraryLoading = true; libraryError = nil
        let epoch = generation
        defer {
            if generation == epoch {
                libraryLoading = false
            }
        }
        do {
            async let a = api.command(
                "music/albums/library_items",
                args: ["limit": .number(100), "order_by": .string("timestamp_added_desc")]
            )
            async let p = api.command("music/playlists/library_items", args: ["limit": .number(100)])
            async let t = api.command("music/tracks/library_items", args: ["limit": .number(100)])
            let (albumData, playlistData, trackData) = try await (a, p, t)
            guard epoch == generation else { return }
            albums = Self.items(albumData); playlists = Self.items(playlistData); tracks = Self.items(trackData)
            for (collection, items) in [("albums", albums), ("playlists", playlists), ("tracks", tracks)] {
                librarySnapshots[collection] = Self.cachedItems(items, adding: librarySnapshots[collection] ?? [])
            }
            saveLibrary()
        } catch {
            if epoch == generation {
                libraryError = error.localizedDescription
            }
        }
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attempt = UUID()
        searchGeneration = attempt
        searchDebouncing = true
        defer {
            if searchGeneration == attempt {
                searchDebouncing = false
            }
        }
        for kind in Self.searchKinds {
            searchPages[kind]?.reset(query.isEmpty ? nil : .search(query: query, kind: kind))
        }
        guard !query.isEmpty else { return }
        if connection != .connected || isDemo {
            let matches = ["albums", "playlists", "tracks"].flatMap { cachedLibraryItems($0) }
                .filter { ($0.name + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }
            for kind in Self.searchKinds {
                searchPages[kind]?.reset(cached: matches.filter { $0.kind == kind })
            }
            return
        }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard searchGeneration == attempt else { return }
        searchDebouncing = false
        await withTaskGroup(of: Void.self) { group in
            for kind in Self.searchKinds {
                group.addTask { await self.loadSearchPage(kind) }
            }
        }
    }

    func loadSearchPage(_ kind: String) async {
        guard connection == .connected, !isDemo, !searchDebouncing, let page = searchPages[kind],
              page.request == .search(query: searchText.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        else { return }
        await page.loadNext { request, offset, limit in
            try await self.fetchMediaPage(request, offset: offset, limit: limit)
        }
    }

    func loadLibraryPage(_ page: MediaPager) async {
        guard connection == .connected, !isDemo, !page.isLoading, page.hasMore else { return }
        let epoch = generation
        let request = page.request
        await page.loadNext { request, offset, limit in
            try await self.fetchMediaPage(request, offset: offset, limit: limit)
        }
        guard epoch == generation, connection == .connected, page.request == request, page.error == nil,
              case let .library(
                  collection,
                  query,
                  _
              ) = page.request, query.isEmpty else { return }
        // Keep a bounded offline snapshot; scrolling itself has no item cap.
        librarySnapshots[collection] = Self.cachedItems(
            cachedLibraryItems(collection),
            adding: Array(page.items.prefix(500))
        )
        libraryCacheTask?.cancel()
        libraryCacheTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.saveLibrary()
        }
    }

    func cachedLibraryItems(_ collection: String) -> [MediaItem] {
        if let snapshot = librarySnapshots[collection] {
            return snapshot
        }
        switch collection {
        case "albums": return albums
        case "playlists": return playlists
        case "tracks": return tracks
        default: return []
        }
    }

    private static func cachedItems(_ existing: [MediaItem], adding items: [MediaItem]) -> [MediaItem] {
        var ids = Set<String>()
        return Array((existing + items).lazy.filter { ids.insert($0.id).inserted }.prefix(500))
    }

    private func fetchMediaPage(_ request: MediaPageRequest, offset: Int, limit: Int) async throws -> [MediaItem] {
        let epoch = generation
        guard connection == .connected else { throw CancellationError() }
        let result = try await api.command(request.command, args: request.arguments(offset: offset, limit: limit))
        try Task.checkCancellation()
        guard epoch == generation, connection == .connected else { throw CancellationError() }
        return request.items(in: result)
    }

    func loadQueue() async {
        guard connection == .connected, !isDemo, let selection = selectedPlayerID else { return }
        if isDeviceSelected {
            await loadLocalQueue()
            systemMedia?.update()
            return
        }
        let id = selection
        let epoch = generation
        do {
            let result = try await api.command("player_queues/get_active_queue", args: ["player_id": .string(id)])
            guard id == selectedPlayerID, epoch == generation, !Task.isCancelled else { return }
            queue = result == .null ? nil : PlayerQueue(result)
            await loadLocalQueue()
            guard id == selectedPlayerID, epoch == generation, !Task.isCancelled else { return }
            systemMedia?.update()
        } catch is CancellationError {}
        catch {
            if id == selectedPlayerID, epoch == generation {
                self.error = error.localizedDescription
            }
        }
    }

    private func loadLocalQueue() async {
        guard local.isConnected, let id = localPlaybackPlayer?.id else { localQueue = nil; return }
        if id == selectedPlayerID, !isDeviceSelected {
            sendspinQueue = confirmedQueue; return
        }
        let epoch = generation
        do {
            let result = try await api.command("player_queues/get_active_queue", args: ["player_id": .string(id)])
            guard epoch == generation, local.isConnected else { return }
            localQueue = result == .null ? nil : PlayerQueue(result)
        } catch { localQueue = nil }
    }

    func localPlayback(_ command: String) async {
        interruption.cancelResume()
        if usesIndependentPlayback {
            await devicePlayback(command); return
        }
        guard let id = localPlaybackPlayer?.id else { return }
        do {
            if command == "play" {
                try await local.activateAudioSession()
            }
            _ = try await api.command("players/cmd/\(command)", args: ["player_id": .string(id)])
            await loadQueue()
        } catch { self.error = error.localizedDescription }
    }

    func stopLocalPlayer() async {
        interruption.reset()
        endRecoveryTime()
        selectLocalWhenReady = false
        localPlayerEnabled = false
        if !isDemo {
            UserDefaults.standard.set(false, forKey: "localPlayerEnabled")
        }
        localRecoveryTask?.cancel(); localRecoveryTask = nil
        await local.stop()
        sendspinQueue = nil
        systemMedia?.update()
    }

    var queueEditing = false
    private var queueItemsRevision = UUID()
    private var queueReloadRequested = false

    var upcomingQueueItems: [QueueEntry] {
        QueueOrder.upcoming(
            queueItems,
            currentID: queue?.raw["current_item"]["queue_item_id"].string,
            currentIndex: queue?.raw["current_index"].double.map(Int.init)
        )
    }

    func loadQueueItems() async {
        if isDeviceSelected, usesIndependentPlayback {
            queueLoading = false; queueError = nil; return
        }
        guard connection == .connected, let queue, !isDemo, !queueEditing else { return }
        if queueLoading {
            queueReloadRequested = true
            return
        }
        queueReloadRequested = false
        let revision = UUID()
        queueItemsRevision = revision
        let epoch = generation
        queueLoading = true
        queueError = nil
        defer {
            if queueItemsRevision == revision {
                queueLoading = false
                if queueReloadRequested {
                    queueReloadRequested = false
                    Task { await loadQueueItems() }
                }
            }
        }
        do {
            var entries: [QueueEntry] = []
            while true {
                let result = try await api.command("player_queues/items", args: [
                    "queue_id": .string(queue.id), "offset": .number(Double(entries.count)), "limit": .number(100),
                ])
                try Task.checkCancellation()
                guard self.queue?.id == queue.id, epoch == generation, queueItemsRevision == revision else { return }
                let page = (result["items"] == .null ? result.array : result["items"].array).map(QueueEntry.init)
                entries += page
                if page.count < 100 {
                    break
                }
            }
            queueItems = entries
        } catch is CancellationError {}
        catch {
            if self.queue?.id == queue.id, epoch == generation, queueItemsRevision == revision {
                queueError = error.localizedDescription
            }
        }
    }

    func moveQueueItem(_ id: String, shift: Int) async {
        if isDeviceSelected, usesIndependentPlayback {
            deviceAudio.move(id, shift: shift); return
        }
        guard !queueEditing, canControl, let queue, shift != 0,
              let index = upcomingQueueItems.firstIndex(where: { $0.id == id }),
              upcomingQueueItems.indices.contains(index + shift),
              let absolute = queueItems.firstIndex(where: { $0.id == id }) else { return }
        let epoch = generation
        let previous = queueItems
        queueEditing = true
        queueItemsRevision = UUID()
        queueLoading = false
        let moved = queueItems.remove(at: absolute)
        queueItems.insert(moved, at: absolute + shift)
        do {
            _ = try await api.command("player_queues/move_item", args: [
                "queue_id": .string(queue.id), "queue_item_id": .string(id), "pos_shift": .number(Double(shift)),
            ])
        } catch {
            if epoch == generation, self.queue?.id == queue.id {
                queueItems = previous
                self.error = error.localizedDescription
            }
        }
        queueEditing = false
        // Selection may have changed while the server saved the move.
        if epoch == generation {
            await loadQueueItems()
        }
    }

    var mediaOverrides: [String: MediaItem] = [:]
    var libraryActionInFlight = false

    func resolvedMedia(_ item: MediaItem) -> MediaItem {
        mediaOverrides[item.uri] ?? item
    }

    func collectionTracks(_ item: MediaItem) async throws -> [MediaItem] {
        if isDemo {
            return tracks
        }
        guard connection == .connected else {
            if let saved = downloads.collections.first(where: { $0.metadata["uri"].string == item.uri }) {
                return saved.tracks.map(MediaItem.init)
            }
            throw MAError.message("Connect to your server to load these songs, or open Downloads.")
        }
        let epoch = generation
        let result = try await api.command(
            item.kind == "album" ? "music/albums/album_tracks" : "music/playlists/playlist_tracks",
            args: ["item_id": .string(item.itemID), "provider_instance_id_or_domain": .string(item.provider)]
        )
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        return Self.items(result)
    }

    func loadEditablePlaylistPage(_ page: MediaPager) async {
        guard !page.isLoading else { return }
        let request = page.request
        let previousCount = page.items.filter(\.isEditablePlaylist).count
        // Keep raw pages in the pager so read-only playlists still advance the wire offset.
        // Skip an empty visible page without requiring another scroll visibility transition.
        repeat {
            let offset = page.offset
            await loadLibraryPage(page)
            guard !Task.isCancelled, connection == .connected, !isDemo,
                  page.request == request, page.error == nil, page.offset > offset else { return }
        } while page.hasMore && page.items.filter(\.isEditablePlaylist).count == previousCount
    }

    func toggleFavorite(_ original: MediaItem) async {
        guard !libraryActionInFlight, connection == .connected else { return }
        if isDemo {
            error = "Connect to your server to save favorites."; return
        }
        libraryActionInFlight = true
        let epoch = generation
        defer { libraryActionInFlight = false }
        do {
            // Resolve provider results to their library identity before removing a favorite.
            let item = try await MediaItem(api.command("music/item_by_uri", args: ["uri": .string(original.uri)]))
            if item.isFavorite {
                guard item.provider == "library"
                else { throw MAError.message("This favorite is not in your library. Refresh and try again.") }
                _ = try await api.command("music/favorites/remove_item", args: [
                    "media_type": .string(item.kind), "library_item_id": .string(item.itemID),
                ])
            } else {
                _ = try await api.command("music/favorites/add_item", args: ["item": .string(original.uri)])
            }
            guard epoch == generation else { return }
            let updated = MediaItem(item.raw.merging(["favorite": .bool(!item.isFavorite)]))
            mediaOverrides[original.uri] = updated
            mediaOverrides[item.uri] = updated
        } catch {
            if epoch == generation {
                self.error = error.localizedDescription
            }
        }
    }

    func addToPlaylist(_ item: MediaItem, playlist: MediaItem) async throws {
        guard !isDemo else { throw MAError.message("Connect to your server to edit playlists.") }
        let epoch = generation
        let songs = item.isCollection ? try await collectionTracks(item) : [item]
        guard epoch == generation else { throw CancellationError() }
        guard !songs.isEmpty else { throw MAError.message("There are no songs to add.") }
        _ = try await api.command("music/playlists/add_playlist_tracks", args: [
            "db_playlist_id": .string(playlist.itemID), "uris": .array(songs.map { .string($0.uri) }),
        ])
    }

    func play(_ item: MediaItem, option: String = "replace") async {
        if await playIndependentlyIfPossible(item, option: option) {
            return
        }
        if isDeviceSelected, !isDemo {
            usesIndependentPlayback = false
            await startLocalPlayer()
            _ = await waitForSendspinPlayer()
            guard isDeviceSelected else { return }
            guard local.isConnected, let target = localPlaybackPlayer, target.available else {
                error = "This device is connecting. Try playing again in a moment."; return
            }
        }
        guard connection == .connected, !queueEditing else { return }
        guard let selected = selectedPlayer, selected.available else { showPlayers = true; return }
        let player = isDeviceSelected ? localPlaybackPlayer ?? selected : selected
        if isLocalPlayer(player) {
            interruption.cancelResume()
            do { try await local.activateAudioSession() }
            catch { self.error = error.localizedDescription; return }
        }
        await perform {
            let active = try await self.api.command(
                "player_queues/get_active_queue",
                args: ["player_id": .string(player.id)]
            )
            let target = active["queue_id"].string ?? player.id
            _ = try await self.api.command(
                "player_queues/play_media",
                args: ["queue_id": .string(target), "media": .array([.string(item.uri)]), "option": .string(option)]
            )
        }
    }

    func playback(_ command: String) async {
        if isDeviceSelected, usesIndependentPlayback {
            if command == "play", audioSupportChecked, !independentAudioAvailable,
               connection == .connected, let current, !downloads.isAvailable(current)
            {
                await moveDeviceQueueToSendspin(); return
            }
            interruption.cancelResume(); await devicePlayback(command); return
        }
        guard connection == .connected, let selected = selectedPlayer, selected.available else { return }
        let player = isDeviceSelected ? localPlaybackPlayer ?? selected : selected
        if isLocalPlayer(player) {
            interruption.cancelResume()
            if command == "play" {
                do { try await local.activateAudioSession() }
                catch { self.error = error.localizedDescription; return }
            }
        }
        await perform(predict: {
            if ["play", "pause", "stop"].contains(command) {
                self.predictedQueue = self.queue?
                    .predicting(["state": .string(command == "play" ? "playing" : command == "pause" ? "paused" :
                            "idle")])
            }
        }) {
            _ = try await self.api.command("players/cmd/\(command)", args: ["player_id": .string(player.id)])
        }
    }

    func togglePlayback() async {
        await playback(queue?.isPlaying == true ? "pause" : "play")
    }

    func queueCommand(_ name: String, args: [String: JSONValue] = [:], queueID: String? = nil) async {
        guard let id = queueID ?? queue?.id else { return }
        if id == DevicePlaybackQueue.playerID {
            interruption.cancelResume()
            switch name {
            case "seek": if let position = args["position"]?.double {
                    await deviceAudio.seek(position)
                }
            case "shuffle": deviceAudio.setShuffle(args["shuffle_enabled"]?.bool == true)
            case "repeat": deviceAudio.setRepeat(args["repeat_mode"]?.string ?? "off")
            case "play_index": if let entry = args["index"]?.string {
                    deviceAudio.select(entry)
                }
            case "delete_item": if let entry = args["item_id_or_index"]?.string {
                    deviceAudio.remove(entry)
                }
            default: break
            }
            return
        }
        if name == "play_index", id == localQueue?.id {
            interruption.cancelResume()
            do { try await local.activateAudioSession() }
            catch { self.error = error.localizedDescription; return }
        }
        await perform(predict: {
            guard id == self.queue?.id else { return }
            let fields: [String: JSONValue] = switch name {
            case "shuffle": ["shuffle_enabled": args["shuffle_enabled"] ?? .bool(false)]
            case "repeat": ["repeat_mode": args["repeat_mode"] ?? .string("off")]
            case "seek": ["elapsed_time": args["position"] ?? .number(0)]
            default: [:]
            }
            self.predictedQueue = self.queue?.predicting(fields)
        }) { _ = try await self.api.command(
            "player_queues/\(name)",
            args: args.merging(["queue_id": .string(id)]) { _, new in new }
        ) }
    }

    func showsVolume(for player: Player) -> Bool {
        !isLocalPlayer(player) && player.volume != nil
    }

    func isLocalPlayer(_ player: Player) -> Bool {
        player.id == DevicePlaybackQueue.playerID || player.represents(localPlayerID: local.clientID)
    }

    var localPlaybackPlayer: Player? {
        availablePlayers.first { isLocalPlayer($0) }
    }

    var selectedPlayerName: String? {
        selectedPlayer.map { isLocalPlayer($0) ? "This Device" : $0.name }
    }

    func setVolume(_ value: Double, player: Player) {
        guard connection == .connected, !isDemo, player.available, showsVolume(for: player) else { return }
        let epoch = generation
        volumeControl.set(value, playerID: player.id, send: { [weak self] volume in
            guard let self, generation == epoch else { throw CancellationError() }
            _ = try await api.command(
                "players/cmd/group_volume",
                args: ["player_id": .string(player.id), "volume_level": .number(volume)]
            )
            // Keep the optimistic value until the device publishes it, with a bounded wait.
            for attempt in 0 ..< 5 {
                try Task.checkCancellation()
                guard generation == epoch else { throw CancellationError() }
                try await refreshPlayers()
                if confirmedPlayers.first(where: { $0.id == player.id })?.volume == volume {
                    break
                }
                if attempt < 4 {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        }, onError: { [weak self] error in self?.error = error.localizedDescription })
    }

    func join(_ player: Player, to leader: Player) async {
        guard player.canJoin(leader) else { return }
        await perform { _ = try await self.api.command(
            "players/cmd/group",
            args: ["player_id": .string(player.id), "target_player": .string(leader.id)]
        ) }
    }

    func ungroup(_ player: Player) async {
        await perform { _ = try await self.api.command("players/cmd/ungroup", args: ["player_id": .string(player.id)]) }
    }

    func selectPlayer(_ player: Player) {
        selectLocalWhenReady = false
        selectedPlayerID = isLocalPlayer(player) ? DevicePlaybackQueue.playerID : player.id
    }

    func startLocalPlayer() async {
        guard !isDemo else { return }
        selectedPlayerID = DevicePlaybackQueue.playerID
        if independentAudioAvailable, !deviceIsGrouped {
            usesIndependentPlayback = true; return
        }
        if connection != .connected, !downloads.records.isEmpty {
            usesIndependentPlayback = true; return
        }
        selectLocalWhenReady = true
        if let player = localPlaybackPlayer, player.available, local.isConnected {
            selectedPlayerID = DevicePlaybackQueue.playerID
            selectLocalWhenReady = false
        }
        localPlayerEnabled = true
        UserDefaults.standard.set(true, forKey: "localPlayerEnabled")
        ensureLocalPlayer()
    }

    private func ensureLocalPlayer() {
        guard localPlayerEnabled, localRecoveryTask == nil, !isDemo else { return }
        let epoch = generation
        localRecoveryTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self, generation == epoch, localPlayerEnabled else { return }
                if connection == .connected, !interruption.isInterrupted, !interruption.isResuming, !resettingAudio,
                   let server,
                   let token
                {
                    if !local.isConnected, !local.isStarting {
                        do {
                            try await local.start(server: server, token: token, api: api)
                            try Task.checkCancellation()
                            guard generation == epoch else { return }
                            try await refreshPlayers()
                            await loadQueue()
                            if local.isConnected {
                                endRecoveryTime()
                            }
                            delay = local.isConnected ? 1 : min(delay * 2, 30)
                        } catch is CancellationError { return }
                        catch { delay = min(delay * 2, 30) }
                    } else {
                        if selectLocalWhenReady {
                            try? await refreshPlayers()
                        }
                        delay = 1
                    }
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func beginAudioInterruption() {
        if usesIndependentPlayback {
            let target = InterruptedPlayback(playerID: DevicePlaybackQueue.playerID, queue: localQueue)
            interruption.begin(target) { [weak self] in self?.deviceAudio.pause() }
            return
        }
        guard localPlayerEnabled else { return }
        let target = InterruptedPlayback(playerID: localPlaybackPlayer?.id, queue: localQueue)
        beginRecoveryTime()
        interruption.begin(target) { [weak self] in
            guard let self else { return }
            await local.markAudioSessionInactive()
            try Task.checkCancellation()
            guard let target else { return }
            // Lifecycle commands must never be dropped by the UI's command lock.
            _ = try await api.command("players/cmd/pause", args: ["player_id": .string(target.playerID)])
        }
    }

    func endAudioInterruption(shouldResume: Bool) async {
        if usesIndependentPlayback {
            try? await interruption.end(shouldResume: shouldResume) { [self] target in
                guard usesIndependentPlayback,
                      target.matches(playerID: DevicePlaybackQueue.playerID, queue: localQueue) else { return }
                deviceAudio.play()
            }
            return
        }
        beginRecoveryTime()
        defer { endRecoveryTime() }
        do {
            try await interruption.end(shouldResume: shouldResume) { [self] target in
                let interruptionRevision = interruption.revision
                guard localPlayerEnabled, let server, let token else { return }
                let epoch = generation
                if connection != .connected {
                    reconnectTask?.cancel(); reconnectTask = nil
                    _ = try await api.connect(server: server, token: token)
                    guard generation == epoch else { return }
                    connection = .connected
                    connectionError = nil
                }
                if !local.isConnected {
                    try await local.start(server: server, token: token, api: api)
                }
                try await refreshPlayers()
                await loadLocalQueue()
                guard generation == epoch, localPlayerEnabled, interruption.revision == interruptionRevision,
                      interruption.playback == target,
                      target.matches(playerID: localPlaybackPlayer?.id, queue: localQueue) else { return }
                try await local.activateAudioSession()
                guard interruption.revision == interruptionRevision, interruption.playback == target,
                      !interruption.isInterrupted, generation == epoch else { return }
                _ = try await api.command("players/cmd/play", args: ["player_id": .string(target.playerID)])
                await loadQueue()
            }
        } catch {
            self.error = "Couldn’t resume playback: \(error.localizedDescription)"
            if connection != .connected {
                scheduleReconnect(immediate: true)
            }
        }
        ensureLocalPlayer()
    }

    func audioRouteDisconnected() async {
        interruption.cancelResume()
        if usesIndependentPlayback {
            deviceAudio.pause(); return
        }
        guard localPlayerEnabled else { return }
        beginRecoveryTime()
        defer { endRecoveryTime() }
        await localPlayback("pause")
    }

    func audioServicesReset() async {
        interruption.reset()
        if usesIndependentPlayback {
            deviceAudio.resetAudioServices(); return
        }
        guard localPlayerEnabled else { return }
        beginRecoveryTime()
        defer { endRecoveryTime() }
        resettingAudio = true
        defer { resettingAudio = false }
        // Recreate invalid audio objects. A media-services reset requires a user play action.
        await localPlayback("pause")
        await local.stop()
        ensureLocalPlayer()
    }

    private func beginRecoveryTime() {
        #if os(iOS)
            guard recoveryBackgroundTask == .invalid, localPlayerEnabled else { return }
            recoveryBackgroundTask = UIApplication.shared
                .beginBackgroundTask(withName: "Restore local playback") { [weak self] in
                    Task { @MainActor [weak self] in self?.endRecoveryTime() }
                }
        #endif
    }

    private func endRecoveryTime() {
        #if os(iOS)
            guard recoveryBackgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(recoveryBackgroundTask)
            recoveryBackgroundTask = .invalid
        #endif
    }

    func retryConnection() {
        guard hasSavedSession, connection != .connected else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        scheduleReconnect(immediate: true)
    }

    func refreshAfterForeground() async {
        guard !isDemo else { return }
        if connection != .connected {
            retryConnection(); return
        }
        checkAudioSupport()
        ensureLocalPlayer()
        do { try await refreshPlayers(); await loadQueue() }
        catch { scheduleReconnect() }
    }

    /// Cache display metadata only, scoped to the server. This is not downloaded audio.
    private var libraryCacheKey: String? {
        server.map { "libraryCache:" + $0.baseURL.absoluteString }
    }

    private func saveLibrary() {
        guard let key = libraryCacheKey else { return }
        func metadata(_ items: [MediaItem]) -> JSONValue {
            .array(items.map { item in
                .object([
                    "uri": .string(item.uri),
                    "name": .string(item.name),
                    "media_type": .string(item.kind),
                    "artists": .array(item.raw["artists"].array.map { .object(["name": $0["name"]]) }),
                    "duration": .number(item.duration),
                ])
            })
        }
        let value = JSONValue.object([
            "albums": metadata(cachedLibraryItems("albums")),
            "playlists": metadata(cachedLibraryItems("playlists")),
            "tracks": metadata(cachedLibraryItems("tracks")),
        ])
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func restoreLibrary() {
        guard let key = libraryCacheKey, let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        albums = Self.items(value["albums"]); playlists = Self.items(value["playlists"]); tracks = Self
            .items(value["tracks"])
        librarySnapshots = ["albums": albums, "playlists": playlists, "tracks": tracks]
    }

    private func perform(predict: () -> Void = {}, _ action: () async throws -> Void) async {
        guard !commandInFlight else { return }
        if isDemo {
            error = "Preview mode shows the interface. Connect to your server to play music."; return
        }
        guard connection == .connected else { return }
        let epoch = generation
        commandInFlight = true
        predict()
        systemMedia?.update()
        defer {
            if epoch == generation {
                predictedQueue = nil
                commandInFlight = false
                systemMedia?.update()
            }
        }
        do { try await action() }
        catch {
            if epoch == generation {
                self.error = error.localizedDescription
            }
            return
        }
        // A refresh failure must not be reported as a failed command or replay the action.
        do {
            try await refreshPlayers(); await loadQueue()
            // Some devices acknowledge before publishing their new state. Keep the
            // prediction during a bounded reconciliation window, then trust the server.
            for _ in 0 ..< 4 {
                guard epoch == generation, connection == .connected else { break }
                let queueMatches = predictedQueue.map { predicted in
                    guard let confirmedQueue, confirmedQueue.id == predicted.id else { return true }
                    return confirmedQueue.isPlaying == predicted.isPlaying &&
                        confirmedQueue.shuffle == predicted.shuffle && confirmedQueue.repeatMode == predicted
                        .repeatMode &&
                        abs(confirmedQueue.elapsed() - predicted.elapsed()) < 3
                } ?? true
                if queueMatches {
                    break
                }
                try await Task.sleep(for: .milliseconds(400))
                try await refreshPlayers(); await loadQueue()
            }
        } catch {
            if epoch == generation {
                scheduleReconnect()
            }
        }
    }

    private func handle(_ event: JSONValue) {
        let name = event["event"].string ?? ""
        if name == "connection_lost" {
            if connection != .connecting {
                scheduleReconnect()
            }
            return
        }
        guard connection == .connected else { return }
        if name == "player_added" || name == "player_updated" {
            let player = Player(event["data"])
            guard !player.id.isEmpty else { return }
            confirmedPlayers.removeAll { $0.id == player.id }; confirmedPlayers.append(player)
            confirmedPlayers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else if name == "player_removed" {
            confirmedPlayers.removeAll { $0.id == event["object_id"].string }
        }
        if name.hasPrefix("player_") {
            systemMedia?.update()
        }
        if name == "queue_items_updated", event["object_id"].string == queue?.id {
            // Reordering can leave the queue's playback snapshot unchanged.
            Task { await loadQueueItems() }
        }
        if name.hasPrefix("queue_") || name.hasPrefix("player_") {
            // Coalesce event bursts; current progress is interpolated locally between snapshots.
            guard queueRefreshTask == nil else { return }
            queueRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                await loadQueue()
                queueRefreshTask = nil
            }
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard let server, let token, connection != .disconnected else { return }
        connection = .reconnecting
        volumeControl.cancel()
        systemMedia?.update()
        guard reconnectTask == nil else { return }
        let epoch = generation
        reconnectTask = Task { [weak self] in
            var delay = immediate ? 0 : 1
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard let self, generation == epoch else { return }
                    _ = try await api.connect(server: server, token: token)
                    guard !Task.isCancelled else { return }
                    connection = .connected
                    connectionError = nil
                    try await refreshPlayers()
                    await loadQueue()
                    await loadLibrary()
                    guard connection == .connected else {
                        throw MAError.message("Connection interrupted while refreshing.")
                    }
                    checkAudioSupport()
                    ensureLocalPlayer()
                    reconnectTask = nil
                    return
                } catch {
                    guard !Task.isCancelled, let self, generation == epoch else { return }
                    connection = .reconnecting
                    connectionError = error.localizedDescription
                    delay = min(max(1, delay * 2), 30)
                }
            }
        }
    }

    private static func items(_ value: JSONValue) -> [MediaItem] {
        (value["items"] == .null ? value.array : value["items"].array).map(MediaItem.init)
    }
}

extension AppModel {
    var isDeviceSelected: Bool {
        selectedPlayerID == DevicePlaybackQueue.playerID
    }

    var deviceIsGrouped: Bool {
        guard let player = localPlaybackPlayer else { return false }
        return player.leader != nil || player.members.contains { $0 != player.id }
    }

    var devicePlaybackStatus: String {
        if deviceAudio.isBuffering, usesIndependentPlayback {
            return "Preparing your music…"
        }
        if usesIndependentPlayback, deviceAudio.wantsPlayback {
            return "Playing on this device"
        }
        if deviceIsGrouped {
            return "Playing with your speakers"
        }
        if connection != .connected {
            return "Downloaded music is ready offline"
        }
        return usesIndependentPlayback ? "Ready to play" : local.status
    }

    var devicePlaybackError: String? {
        usesIndependentPlayback ? deviceAudio.error : local.error
    }

    func artworkURL(for item: MediaItem) -> URL? {
        if let local = downloads.artworkURLs[item.uri] {
            return local
        }
        if item.isCollection, let saved = downloads.collections.first(where: { $0.metadata["uri"].string == item.uri }),
           let local = saved.tracks.compactMap({ downloads.artworkURLs[MediaItem($0).uri] }).first
        {
            return local
        }
        return item.artworkURL(server: server)
    }

    func isDownloaded(_ item: MediaItem) -> Bool {
        if !item.isCollection {
            return downloads.isDownloaded(item)
        }
        guard let collection = downloads.collections.first(where: { $0.metadata["uri"].string == item.uri }),
              !collection.tracks.isEmpty else { return false }
        return collection.tracks.allSatisfy { downloads.isDownloaded(MediaItem($0)) }
    }

    func removeDownload(_ item: MediaItem) async {
        if item.isCollection,
           let collection = downloads.collections.first(where: { $0.metadata["uri"].string == item.uri })
        {
            for song in collection.tracks {
                await downloads.remove(MediaItem(song))
            }
        } else {
            await downloads.remove(item)
        }
    }

    func playDownloads(_ songs: [MediaItem], shuffled: Bool = false) async {
        guard !isDemo, !songs.isEmpty else { return }
        interruption.cancelResume()
        selectedPlayerID = DevicePlaybackQueue.playerID
        if !usesIndependentPlayback, local.isConnected {
            guard await listenSeparately(restoreQueue: false) else { return }
        }
        usesIndependentPlayback = true
        deviceAudio.setShuffle(shuffled)
        deviceAudio.insert(songs, option: "replace")
    }

    var deviceGroupTargets: [Player] {
        availablePlayers.filter { player in
            !isLocalPlayer(player) && player.available && player.leader == nil &&
                (localPlaybackPlayer?.canJoin(player) == true || player.provider == "sendspin")
        }
    }

    func enableSharedPlayback(_ enabled: Bool) async {
        if enabled {
            localPlayerEnabled = true
            UserDefaults.standard.set(true, forKey: "localPlayerEnabled")
            ensureLocalPlayer()
        } else {
            await stopLocalPlayer()
        }
    }

    @discardableResult func listenSeparately(restoreQueue: Bool = true) async -> Bool {
        let epoch = generation
        let snapshot = sendspinQueue
        var entries: [QueueEntry] = []
        do {
            if let device = localPlaybackPlayer, connection == .connected {
                if restoreQueue, let snapshot {
                    while true {
                        let result = try await api.command("player_queues/items", args: [
                            "queue_id": .string(snapshot.id), "offset": .number(Double(entries.count)),
                            "limit": .number(100),
                        ])
                        guard epoch == generation else { return false }
                        let page = Self.itemsArray(result).map(QueueEntry.init)
                        entries += page
                        if page.count < 100 {
                            break
                        }
                    }
                }
                if device.canLeave || device.members.count > 1 {
                    _ = try await api.command("players/cmd/ungroup", args: ["player_id": .string(device.id)])
                }
                _ = try await api.command("players/cmd/stop", args: ["player_id": .string(device.id)])
            }
            guard epoch == generation else { return false }
            await local.stop(forRestart: true)
            if connection == .connected {
                try await refreshPlayers()
            }
            usesIndependentPlayback = true
            selectedPlayerID = DevicePlaybackQueue.playerID
            sendspinQueue = nil
            if restoreQueue, !entries.isEmpty, let snapshot {
                let id = snapshot.raw["current_item"]["queue_item_id"].string
                let index = entries.firstIndex { $0.id == id } ?? 0
                deviceAudio.adopt(
                    entries.map(\.media),
                    index: index,
                    position: snapshot.elapsed(),
                    playing: snapshot.isPlaying
                )
            }
            systemMedia?.update()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private static func itemsArray(_ result: JSONValue) -> [JSONValue] {
        result["items"] == .null ? result.array : result["items"].array
    }

    func canPlay(_ item: MediaItem) -> Bool {
        guard !commandInFlight, !queueEditing else { return false }
        if connection == .connected {
            return true
        }
        if item.isCollection {
            return downloads.collections.first(where: { $0.metadata["uri"].string == item.uri })?
                .tracks.contains { downloads.isAvailable(MediaItem($0)) } == true
        }
        return downloads.isAvailable(item)
    }

    private func configureDeviceAudio(address: ServerAddress, token: String) async {
        let changed = downloads.scope != AudioFileStore.scope(server: address, account: token)
        do {
            try await downloads.configure(server: address, token: token)
            if changed {
                await deviceAudio.configure(
                    access: IndependentAudioClient(server: address, token: token),
                    store: downloads.store
                )
            }
            if selectedPlayerID == nil {
                selectedPlayerID = DevicePlaybackQueue.playerID
            }
            deviceAudio.online = connection == .connected
        } catch {
            await deviceAudio.configure(access: IndependentAudioClient(server: address, token: token), store: nil)
            deviceAudio.online = connection == .connected
            self.error = "Couldn’t open your offline library. \(error.localizedDescription)"
        }
    }

    func checkAudioSupport(force: Bool = false) {
        guard !isDemo, audioSupportTask == nil, !audioSupportChecked || force, let server, let token else { return }
        let epoch = generation
        audioSupportTask = Task { [weak self] in
            guard let self else { return }
            defer { audioSupportTask = nil }
            do {
                let available = try await IndependentAudioClient(server: server, token: token).isAvailable()
                guard epoch == generation else { return }
                independentAudioAvailable = available; audioSupportChecked = true
                if isDeviceSelected, deviceAudio.state.current == nil, !deviceIsGrouped {
                    usesIndependentPlayback = available
                    if !available {
                        await startLocalPlayer()
                    }
                }
            } catch { /* Temporary connection errors must not downgrade a working local session. */ }
        }
    }

    private func reconcileDeviceRoute() {
        if let selectedPlayer, selectedPlayer.represents(localPlayerID: local.clientID) {
            selectedPlayerID = DevicePlaybackQueue.playerID
        }
        if deviceIsGrouped, usesIndependentPlayback {
            deviceAudio.pause(); usesIndependentPlayback = false
        }
    }

    private func playIndependentlyIfPossible(_ item: MediaItem, option: String) async -> Bool {
        guard !isDemo else { return false }
        // Offline music always targets this device; a lost room never starts another speaker.
        if connection != .connected, canPlay(item) {
            selectedPlayerID = DevicePlaybackQueue.playerID
        }
        guard isDeviceSelected, !deviceIsGrouped || connection != .connected else { return false }
        if !audioSupportChecked, connection == .connected {
            checkAudioSupport()
            await audioSupportTask?.value
        }
        guard independentAudioAvailable || downloads.isAvailable(item) || connection != .connected else { return false }
        guard !commandInFlight, !queueEditing else { return true }
        commandInFlight = true
        let epoch = generation
        defer { commandInFlight = false }
        do {
            var songs = item.isCollection ? try await collectionTracks(item) : [item]
            if connection != .connected {
                songs = songs.filter { downloads.isAvailable($0) }
            }
            guard !songs.isEmpty else { throw MAError.message("No songs from this selection are available offline.") }
            guard songs.allSatisfy({ $0.kind == "track" && $0.duration > 0 }) else {
                // Live sources continue through the synchronized transport.
                return false
            }
            guard epoch == generation, isDeviceSelected else { return true }
            if !usesIndependentPlayback, connection == .connected, sendspinQueue?.isPlaying == true,
               let player = localPlaybackPlayer
            {
                _ = try await api.command("players/cmd/pause", args: ["player_id": .string(player.id)])
            }
            if !usesIndependentPlayback, connection != .connected {
                await local.stop(forRestart: true)
            }
            interruption.cancelResume()
            usesIndependentPlayback = true
            deviceAudio.insert(songs, option: option)
            systemMedia?.update()
        } catch { self.error = error.localizedDescription }
        return true
    }

    private func devicePlayback(_ command: String) async {
        guard !isDemo else { return }
        switch command {
        case "play": deviceAudio.play()
        case "pause": deviceAudio.pause()
        case "stop": deviceAudio.stop()
        case "next": deviceAudio.next()
        case "previous": deviceAudio.previous()
        default: break
        }
        systemMedia?.update()
    }

    func download(_ item: MediaItem) async {
        guard !isDemo else { error = "Connect to your server to download music."; return }
        guard independentAudioAvailable || downloads.isAvailable(item) else {
            error = "Your server needs the optional Music Assistant One audio companion to prepare downloads. Online playback and speaker control are still available."
            return
        }
        let epoch = generation
        do {
            let songs = item.isCollection ? try await collectionTracks(item) : [item]
            guard epoch == generation else { return }
            guard !songs.isEmpty, songs.allSatisfy({ $0.kind == "track" && $0.duration > 0 }) else {
                throw MAError
                    .message("Only songs, albums, and playlists can be downloaded. Live streams can’t be saved.")
            }
            if item.isCollection {
                try await downloads.saveCollection(item, tracks: songs)
            }
            try await downloads.enqueue(songs)
        } catch { self.error = error.localizedDescription }
    }

    func joinThisDevice(to player: Player) async {
        guard connection == .connected, !isDemo else { return }
        localPlayerEnabled = true
        UserDefaults.standard.set(true, forKey: "localPlayerEnabled")
        ensureLocalPlayer()
        guard await waitForSendspinPlayer(), let device = localPlaybackPlayer else {
            error = "Couldn’t connect this device to your speakers. Try again when your server is reachable."; return
        }
        await join(device, to: player)
        do { try await refreshPlayers() } catch { self.error = error.localizedDescription }
        if deviceIsGrouped {
            deviceAudio.pause(); usesIndependentPlayback = false; selectedPlayerID = DevicePlaybackQueue
                .playerID; await loadQueue()
        }
    }

    private func waitForSendspinPlayer() async -> Bool {
        for _ in 0 ..< 200 {
            if local.isConnected, localPlaybackPlayer?.available == true {
                return true
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            guard connection == .connected else { return false }
        }
        return false
    }

    /// An optional provider can be removed while the app is open. A retry transfers
    /// the remaining device queue to its synchronized transport, preserving position.
    private func moveDeviceQueueToSendspin() async {
        guard !commandInFlight, let index = deviceAudio.state.currentIndex else { return }
        let snapshot = deviceAudio.state
        let epoch = generation
        commandInFlight = true
        defer { commandInFlight = false }
        deviceAudio.pause()
        await startLocalPlayer()
        guard await waitForSendspinPlayer(), epoch == generation, isDeviceSelected,
              deviceAudio.state.currentID == snapshot.currentID, let player = localPlaybackPlayer
        else {
            error = "Couldn’t reconnect playback. Try again when your server is reachable."; return
        }
        do {
            let active = try await api.command(
                "player_queues/get_active_queue",
                args: ["player_id": .string(player.id)]
            )
            let id = active["queue_id"].string ?? player.id
            _ = try await api.command("player_queues/play_media", args: [
                "queue_id": .string(id), "option": .string("replace"),
                "media": .array(snapshot.entries.dropFirst(index).map { .string($0.media.uri) }),
            ])
            guard epoch == generation, isDeviceSelected else { return }
            usesIndependentPlayback = false
            if snapshot.position > 0 {
                _ = try await api.command(
                    "player_queues/seek",
                    args: ["queue_id": .string(id), "position": .number(snapshot.position.rounded())]
                )
            }
            _ = try await api.command(
                "player_queues/repeat",
                args: ["queue_id": .string(id), "repeat_mode": .string(snapshot.repeatMode)]
            )
            await loadQueue()
        } catch { self.error = error.localizedDescription }
    }
}

extension AppModel {
    /// Explicit, non-networked fixtures for previews and UI automation only.
    func loadDemo() {
        guard !hasSavedSession else { return }
        isDemo = true
        connection = .connected
        serverName = "Interface preview"
        func item(_ name: String, _ artist: String, _ kind: String = "album") -> MediaItem {
            MediaItem(.object([
                "uri": .string("preview://\(kind)/\(name)"),
                "name": .string(name),
                "media_type": .string(kind),
                "artists": .array([.object(["name": .string(artist)])]),
                "duration": .number(243),
            ]))
        }
        albums = [
            item("Open Water", "The Quiet Hours"),
            item("After the Rain", "June & August"),
            item("Somewhere, Slowly", "Northbound"),
            item("Golden Hour", "The Quiet Hours"),
            item("A Little Closer", "Paper Planes"),
            item("Blue in Green", "Sunday Sessions"),
        ]
        playlists = [
            item("A slow morning", "Your library", "playlist"),
            item("On the way home", "Your library", "playlist"),
        ]
        tracks = [item("Open Water", "The Quiet Hours", "track"), item("First Light", "June & August", "track")]
        players = [
            Player(.object([
                "player_id": .string("living"),
                "name": .string("Living Room"),
                "available": .bool(true),
                "provider": .string("sendspin"),
                "volume_level": .number(35),
                "playback_state": .string("paused"),
                "can_group_with": .array([.string("sendspin")]),
            ])),
            Player(.object([
                "player_id": .string("kitchen"),
                "name": .string("Kitchen"),
                "available": .bool(true),
                "provider": .string("sendspin"),
                "volume_level": .number(25),
                "can_group_with": .array([.string("sendspin")]),
            ])),
        ]
        selectedPlayerID = "living"
        queueItems = tracks.enumerated().map { index, track in
            QueueEntry(.object(["queue_item_id": .string("preview-\(index)"), "media_item": track.raw]))
        }
        queue = PlayerQueue(.object([
            "queue_id": .string("living"),
            "state": .string("paused"),
            "elapsed_time": .number(67),
            "current_item": .object([
                "queue_item_id": .string("preview-0"),
                "duration": .number(243),
                "media_item": tracks[0].raw,
            ]),
        ]))
    }
}

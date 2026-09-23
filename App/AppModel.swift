import Foundation
import MusicAssistantCore
import Network
import Observation

@MainActor @Observable
final class AppModel {
    enum Connection: Equatable { case disconnected, connecting, connected, reconnecting }
    var connection: Connection = .disconnected
    var server: ServerAddress?
    var serverName = "Music Assistant"
    var serverVersion = ""
    private(set) var connectionError: String?
    var error: String?
    private var confirmedPlayers: [Player] = []
    private var predictedVolume: (id: String, value: Double)?
    var players: [Player] {
        get { confirmedPlayers.map { player in
            guard let predictedVolume, predictedVolume.id == player.id else { return player }
            return Player(player.raw.merging(["group_volume": .number(predictedVolume.value)]))
        } }
        set { confirmedPlayers = newValue }
    }

    var selectedPlayerID: String? {
        didSet {
            guard oldValue != selectedPlayerID else { return }
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
        get { predictedQueue?.id == confirmedQueue?.id ? predictedQueue ?? confirmedQueue : confirmedQueue }
        set { confirmedQueue = newValue }
    }

    var localQueue: PlayerQueue?
    var queueItems: [QueueEntry] = []
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
        players.first { $0.id == selectedPlayerID }
    }

    var availablePlayers: [Player] {
        players.filter { $0.isVisiblePlaybackTarget(localPlayerID: local.clientID) }
    }

    var canControl: Bool {
        connection == .connected && selectedPlayer?.available == true && !commandInFlight
    }

    var current: MediaItem? {
        queue?.current
    }

    func start() async {
        guard eventTask == nil else { return }
        systemMedia = SystemMedia(model: self)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.connection == .reconnecting else { return }
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
        selectedPlayerID = UserDefaults.standard.string(forKey: "selectedPlayerID")
        ensureLocalPlayer()
        do { try await refreshPlayers(); await loadQueue(); await loadLibrary() }
        catch { scheduleReconnect() }
    }

    func disconnect(forget: Bool = false) async {
        generation = UUID()
        predictedQueue = nil; predictedVolume = nil; commandInFlight = false
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
        librarySnapshots = [:]
        isDemo = false
        showNowPlaying = false; showPlayers = false
    }

    func refreshPlayers() async throws {
        guard !isDemo else { return }
        let epoch = generation
        let result = try await api.command("players/all")
        guard epoch == generation, connection == .connected else { return }
        players = result.array.map(Player.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Never silently switch playback to another room after the selected player disappears.
        if selectedPlayerID == nil {
            selectedPlayerID = availablePlayers.first(where: \.available)?.id
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
        guard connection == .connected, !isDemo, let id = selectedPlayerID else { return }
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
        guard local.isConnected, let id = local.clientID else { localQueue = nil; return }
        if id == selectedPlayerID {
            localQueue = queue; return
        }
        let epoch = generation
        do {
            let result = try await api.command("player_queues/get_active_queue", args: ["player_id": .string(id)])
            guard epoch == generation, local.isConnected else { return }
            localQueue = result == .null ? nil : PlayerQueue(result)
        } catch { localQueue = nil }
    }

    func localPlayback(_ command: String) async {
        guard local.isConnected, let id = local.clientID else { return }
        await perform { _ = try await self.api.command("players/cmd/\(command)", args: ["player_id": .string(id)]) }
    }

    func stopLocalPlayer() async {
        localPlayerEnabled = false
        if !isDemo {
            UserDefaults.standard.set(false, forKey: "localPlayerEnabled")
        }
        localRecoveryTask?.cancel(); localRecoveryTask = nil
        await local.stop()
        localQueue = nil
        systemMedia?.clear()
    }

    func loadQueueItems() async {
        guard connection == .connected, let queue, !isDemo else { return }
        let epoch = generation
        queueLoading = true
        queueError = nil
        defer {
            if epoch == generation, self.queue?.id == queue.id {
                queueLoading = false
            }
        }
        do {
            let result = try await api.command(
                "player_queues/items",
                args: ["queue_id": .string(queue.id), "limit": .number(100)]
            )
            try Task.checkCancellation()
            guard self.queue?.id == queue.id, epoch == generation else { return }
            queueItems = result.array.map(QueueEntry.init)
        } catch is CancellationError {}
        catch {
            if self.queue?.id == queue.id, epoch == generation {
                queueError = error.localizedDescription
            }
        }
    }

    func play(_ item: MediaItem, option: String = "replace") async {
        guard connection == .connected else { return }
        guard let player = selectedPlayer, player.available else { showPlayers = true; return }
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
        guard connection == .connected, let player = selectedPlayer, player.available else { return }
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

    func setVolume(_ value: Double, player: Player) async {
        await perform(predict: { self.predictedVolume = (player.id, value.rounded()) }) {
            _ = try await self.api.command(
                "players/cmd/group_volume",
                args: ["player_id": .string(player.id), "volume_level": .number(value.rounded())]
            )
        }
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

    func startLocalPlayer() async {
        guard !isDemo else { return }
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
                if connection == .connected, let server, let token {
                    if !local.isConnected, !local.isStarting {
                        do {
                            try await local.start(server: server, token: token, api: api)
                            try Task.checkCancellation()
                            guard generation == epoch else { return }
                            try await refreshPlayers()
                            await loadQueue()
                            delay = local.isConnected ? 1 : min(delay * 2, 30)
                        } catch is CancellationError { return }
                        catch { delay = min(delay * 2, 30) }
                    } else {
                        delay = 1
                    }
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
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
                predictedQueue = nil; predictedVolume = nil
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
                let volumeMatches = predictedVolume.map { predicted in
                    confirmedPlayers.first(where: { $0.id == predicted.id })?.volume == predicted.value
                } ?? true
                if queueMatches, volumeMatches {
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
        confirmedQueue = confirmedQueue?.predicting(["state": .string("paused")])
        systemMedia?.clear()
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
    /// Explicit, non-networked fixtures for previews and UI automation only.
    func loadDemo() {
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
            "current_item": .object(["duration": .number(243), "media_item": tracks[0].raw]),
        ]))
    }
}

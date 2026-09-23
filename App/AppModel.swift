import Foundation
import MusicAssistantCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Connection: Equatable { case disconnected, connecting, connected, reconnecting }
    var connection: Connection = .disconnected
    var server: ServerAddress?
    var serverName = "Music Assistant"
    var serverVersion = ""
    var error: String?
    var players: [Player] = []
    var selectedPlayerID: String? {
        didSet {
            guard oldValue != selectedPlayerID else { return }
            if !isDemo { UserDefaults.standard.set(selectedPlayerID, forKey: "selectedPlayerID") }
            queue = nil; queueItems = []
            selectionTask?.cancel()
            selectionTask = Task { await loadQueue() }
        }
    }
    var queue: PlayerQueue?
    var localQueue: PlayerQueue?
    var queueItems: [QueueEntry] = []
    var albums: [MediaItem] = []
    var playlists: [MediaItem] = []
    var tracks: [MediaItem] = []
    var libraryLoading = false
    var libraryError: String?
    var searchText = ""
    var searchResults: [MediaItem] = []
    var searching = false
    var searchError: String?
    var showNowPlaying = false
    var showPlayers = false
    var showConnection = false
    var commandInFlight = false
    let local = LocalPlayer()
    let discovery = ServerDiscovery()
    let api = MusicAssistantClient()
    private var token: String?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var queueRefreshTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isDemo = false
    private var systemMedia: SystemMedia?

    var selectedPlayer: Player? { players.first { $0.id == selectedPlayerID } }
    var availablePlayers: [Player] { players.filter { $0.visible && (!$0.isPrivate || $0.id == local.clientID) } }
    var canControl: Bool { connection == .connected && selectedPlayer?.available == true && !commandInFlight }
    var current: MediaItem? { queue?.current }

    func start() async {
        guard eventTask == nil else { return }
        systemMedia = SystemMedia(model: self)
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            loadDemo()
            return
        }
        eventTask = Task { [weak self, api] in
            for await event in api.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        guard !ProcessInfo.processInfo.arguments.contains("--onboarding"),
              let saved = UserDefaults.standard.string(forKey: "serverAddress") else { return }
        do {
            let address = try ServerAddress(saved)
            if let token = try CredentialStore.token(for: address) {
                try await connect(address: address, token: token, persist: false)
            }
        } catch { self.error = error.localizedDescription }
    }

    func signIn(address: String, username: String, password: String, accessToken: String) async throws {
        let server = try ServerAddress(address)
        connection = .connecting
        do {
            let token = accessToken.isEmpty ? try await MusicAssistantClient.login(server: server, username: username, password: password) : accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            try await connect(address: server, token: token, persist: true)
        } catch {
            await api.disconnect()
            connection = .disconnected
            throw error
        }
    }

    private func connect(address: ServerAddress, token: String, persist: Bool) async throws {
        connection = .connecting
        let info = try await api.connect(server: address, token: token)
        do { if persist { try CredentialStore.save(token, for: address) } }
        catch { await api.disconnect(); connection = .disconnected; throw error }
        generation = UUID()
        server = address; self.token = token
        serverName = info["name"].string ?? "Music Assistant"
        serverVersion = info["server_version"].string ?? ""
        UserDefaults.standard.set(address.baseURL.absoluteString, forKey: "serverAddress")
        connection = .connected
        showConnection = false
        error = nil
        selectedPlayerID = UserDefaults.standard.string(forKey: "selectedPlayerID")
        try await refreshPlayers()
        await loadQueue()
        await loadLibrary()
    }

    func disconnect(forget: Bool = false) async {
        generation = UUID()
        libraryLoading = false; searching = false
        reconnectTask?.cancel(); reconnectTask = nil
        selectionTask?.cancel(); queueRefreshTask?.cancel()
        connection = .disconnected
        await api.disconnect()
        await local.stop()
        systemMedia?.clear()
        if forget, let server {
            do { try CredentialStore.delete(for: server) }
            catch { self.error = error.localizedDescription }
            UserDefaults.standard.removeObject(forKey: "serverAddress")
        }
        token = nil; players = []; queue = nil; localQueue = nil; queueItems = []; selectedPlayerID = nil
        albums = []; playlists = []; tracks = []; searchResults = []; searchText = ""
        isDemo = false
    }

    func refreshPlayers() async throws {
        guard !isDemo else { return }
        let epoch = generation
        let result = try await api.command("players/all")
        guard epoch == generation, connection == .connected else { return }
        players = result.array.map(Player.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Never silently switch playback to another room after the selected player disappears.
        if selectedPlayerID == nil { selectedPlayerID = availablePlayers.first(where: \.available)?.id }
    }

    func loadLibrary() async {
        guard connection == .connected, !isDemo else { return }
        libraryLoading = true; libraryError = nil
        let epoch = generation
        defer { if generation == epoch { libraryLoading = false } }
        do {
            async let a = api.command("music/albums/library_items", args: ["limit": .number(60), "order_by": .string("timestamp_added DESC")])
            async let p = api.command("music/playlists/library_items", args: ["limit": .number(60)])
            async let t = api.command("music/tracks/library_items", args: ["limit": .number(60)])
            let (albumData, playlistData, trackData) = try await (a, p, t)
            guard epoch == generation else { return }
            albums = Self.items(albumData); playlists = Self.items(playlistData); tracks = Self.items(trackData)
        } catch { if epoch == generation { libraryError = error.localizedDescription } }
    }

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil
        guard !query.isEmpty else { searchResults = []; searching = false; return }
        searching = true
        let epoch = generation
        defer { if query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) { searching = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            if isDemo { searchResults = (albums + playlists + tracks).filter { ($0.name + $0.subtitle).localizedCaseInsensitiveContains(query) }; return }
            let result = try await api.command("music/search", args: ["search_query": .string(query), "media_types": .array(["track", "album", "artist", "playlist", "radio"].map(JSONValue.string)), "limit": .number(20)])
            try Task.checkCancellation()
            guard epoch == generation, query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            searchResults = ["tracks", "albums", "artists", "playlists", "radio"].flatMap { Self.items(result[$0]) }
        } catch is CancellationError { }
        catch { if epoch == generation && query == searchText { searchError = error.localizedDescription } }
    }

    func loadQueue() async {
        guard connection == .connected, !isDemo, let id = selectedPlayerID else { return }
        let epoch = generation
        do {
            let result = try await api.command("player_queues/get_active_queue", args: ["player_id": .string(id)])
            guard id == selectedPlayerID, epoch == generation, !Task.isCancelled else { return }
            queue = result == .null ? nil : PlayerQueue(result)
            await loadLocalQueue()
            systemMedia?.update()
        } catch is CancellationError { }
        catch { if id == selectedPlayerID && epoch == generation { self.error = error.localizedDescription } }
    }

    private func loadLocalQueue() async {
        guard local.isConnected, let id = local.clientID else { localQueue = nil; return }
        if id == selectedPlayerID { localQueue = queue; return }
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
        await local.stop()
        localQueue = nil
        systemMedia?.clear()
    }

    func loadQueueItems() async {
        guard let queue, !isDemo else { return }
        do {
            let result = try await api.command("player_queues/items", args: ["queue_id": .string(queue.id), "limit": .number(100)])
            guard self.queue?.id == queue.id else { return }
            queueItems = result.array.map(QueueEntry.init)
        } catch { self.error = error.localizedDescription }
    }

    func play(_ item: MediaItem, option: String = "replace") async {
        guard let player = selectedPlayer, player.available else { showPlayers = true; return }
        await perform {
            let active = try await self.api.command("player_queues/get_active_queue", args: ["player_id": .string(player.id)])
            let target = active["queue_id"].string ?? player.id
            _ = try await self.api.command("player_queues/play_media", args: ["queue_id": .string(target), "media": .array([.string(item.uri)]), "option": .string(option)])
        }
    }

    func playback(_ command: String) async {
        guard let player = selectedPlayer, player.available else { return }
        await perform {
            _ = try await self.api.command("players/cmd/\(command)", args: ["player_id": .string(player.id)])
        }
    }
    func togglePlayback() async { await playback(queue?.isPlaying == true ? "pause" : "play") }
    func queueCommand(_ name: String, args: [String: JSONValue] = [:], queueID: String? = nil) async {
        guard let id = queueID ?? queue?.id else { return }
        await perform { _ = try await self.api.command("player_queues/\(name)", args: args.merging(["queue_id": .string(id)]) { _, new in new }) }
    }
    func setVolume(_ value: Double, player: Player) async {
        await perform { _ = try await self.api.command("players/cmd/group_volume", args: ["player_id": .string(player.id), "volume_level": .number(value.rounded())]) }
    }
    func join(_ player: Player, to leader: Player) async {
        guard player.canJoin(leader) else { return }
        await perform { _ = try await self.api.command("players/cmd/group", args: ["player_id": .string(player.id), "target_player": .string(leader.id)]) }
    }
    func ungroup(_ player: Player) async {
        await perform { _ = try await self.api.command("players/cmd/ungroup", args: ["player_id": .string(player.id)]) }
    }
    func startLocalPlayer() async {
        guard let server, let token else { return }
        let epoch = generation
        do {
            try await local.start(server: server, token: token, api: api)
            guard epoch == generation, connection == .connected else { return }
            try await refreshPlayers()
            selectedPlayerID = local.clientID
            await loadQueue()
        } catch { self.error = error.localizedDescription }
    }

    func refreshAfterForeground() async {
        guard connection == .connected, !isDemo else { return }
        do { try await refreshPlayers(); await loadQueue() }
        catch { scheduleReconnect() }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !commandInFlight else { return }
        if isDemo { error = "Preview mode shows the interface. Connect to your server to play music."; return }
        commandInFlight = true
        defer { commandInFlight = false }
        do { try await action(); try await refreshPlayers(); await loadQueue() }
        catch { self.error = error.localizedDescription }
    }

    private func handle(_ event: JSONValue) {
        let name = event["event"].string ?? ""
        if name == "connection_lost" { scheduleReconnect(); return }
        guard connection == .connected else { return }
        if name == "player_added" || name == "player_updated" {
            let player = Player(event["data"])
            guard !player.id.isEmpty else { return }
            players.removeAll { $0.id == player.id }; players.append(player)
            players.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else if name == "player_removed" {
            players.removeAll { $0.id == event["object_id"].string }
        }
        if name.hasPrefix("queue_") || name.hasPrefix("player_") {
            // Coalesce event bursts; current progress is interpolated locally between snapshots.
            guard queueRefreshTask == nil else { return }
            queueRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                await self.loadQueue()
                self.queueRefreshTask = nil
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let server, let token, connection != .disconnected else { return }
        connection = .reconnecting
        systemMedia?.clear()
        let restoreAudio = local.isConnected
        reconnectTask = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard let self else { return }
                    _ = try await self.api.connect(server: server, token: token)
                    guard !Task.isCancelled else { return }
                    self.connection = .connected
                    try await self.refreshPlayers()
                    await self.loadQueue()
                    if restoreAudio { await self.startLocalPlayer() }
                    self.reconnectTask = nil
                    return
                } catch { delay = min(delay * 2, 30) }
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
            MediaItem(.object(["uri": .string("preview://\(kind)/\(name)"), "name": .string(name),
                "media_type": .string(kind), "artists": .array([.object(["name": .string(artist)])]), "duration": .number(243)]))
        }
        albums = [item("Open Water", "The Quiet Hours"), item("After the Rain", "June & August"),
                  item("Somewhere, Slowly", "Northbound"), item("Golden Hour", "The Quiet Hours"),
                  item("A Little Closer", "Paper Planes"), item("Blue in Green", "Sunday Sessions")]
        playlists = [item("A slow morning", "Your library", "playlist"), item("On the way home", "Your library", "playlist")]
        tracks = [item("Open Water", "The Quiet Hours", "track"), item("First Light", "June & August", "track")]
        players = [Player(.object(["player_id": .string("living"), "name": .string("Living Room"), "available": .bool(true), "provider": .string("sendspin"), "volume_level": .number(35), "playback_state": .string("paused"), "can_group_with": .array([.string("sendspin")])])),
                   Player(.object(["player_id": .string("kitchen"), "name": .string("Kitchen"), "available": .bool(true), "provider": .string("sendspin"), "volume_level": .number(25), "can_group_with": .array([.string("sendspin")])]))]
        selectedPlayerID = "living"
        queue = PlayerQueue(.object(["queue_id": .string("living"), "state": .string("paused"), "elapsed_time": .number(67), "current_item": .object(["duration": .number(243), "media_item": tracks[0].raw])]))
    }
}

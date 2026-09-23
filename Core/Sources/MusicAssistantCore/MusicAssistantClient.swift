import Foundation

/// One authenticated control session. The server remains the source of truth.
public actor MusicAssistantClient {
    public nonisolated let events: AsyncStream<JSONValue>
    private let eventContinuation: AsyncStream<JSONValue>.Continuation
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var chunks: [String: [JSONValue]] = [:]
    private var generation = UUID()

    public init(session: URLSession = .shared) {
        self.session = session
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public static func login(server: ServerAddress, username: String, password: String) async throws -> String {
        var request = URLRequest(url: server.endpoint("auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "provider_id": .string("builtin"), "device_name": .string("Music Assistant One"),
            "credentials": .object(["username": .string(username), "password": .string(password)])
        ]))
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = json["token"].string else {
            throw MAError.message(json["error"].string ?? "Sign-in failed. Check your username and password.")
        }
        return token
    }

    public func connect(server: ServerAddress, token: String) async throws -> JSONValue {
        disconnect()
        let epoch = UUID()
        generation = epoch
        var request = URLRequest(url: server.endpoint("ws", websocket: true))
        request.timeoutInterval = 15
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 16 * 1024 * 1024
        socket = ws
        ws.resume()
        // A bounded greeting wait also handles servers that accept a socket but never speak MA.
        let deadline = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { ws.cancel(with: .goingAway, reason: nil) } }
        defer { deadline.cancel() }
        do {
            let info = try Self.parse(await ws.receive())
            guard let schema = info["schema_version"].double else { throw MAError.message("This address did not return a Music Assistant server.") }
            guard schema >= 28, (info["min_supported_schema_version"].double ?? 28) <= 65 else {
                throw MAError.message("This Music Assistant API version is not supported. This build supports schemas 28–65.")
            }
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try Self.parse(await ws.receive())
                        await self?.receive(message, generation: epoch)
                    }
                } catch { await self?.connectionLost(generation: epoch) }
            }
            _ = try await command("auth", args: ["token": .string(token)])
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(25))
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            ws.sendPing { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            }
                        }
                    } catch {
                        if !Task.isCancelled { await self?.connectionLost(generation: epoch) }
                        return
                    }
                }
            }
            return info
        } catch {
            if generation == epoch { disconnect() }
            throw error
        }
    }

    public func command(_ name: String, args: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let socket else { throw MAError.message("Connect to Music Assistant to continue.") }
        try Task.checkCancellation()
        let id = UUID().uuidString
        let payload = try JSONEncoder().encode(JSONValue.object([
            "message_id": .string(id), "command": .string(name), "args": .object(args)
        ]))
        let text = String(decoding: payload, as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    await self?.finish(id, result: .failure(MAError.message("Music Assistant took too long to respond. Try again.")))
                }
                Task { [weak self] in
                    do { try await socket.send(.string(text)) }
                    catch { await self?.finish(id, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.finish(id, result: .failure(CancellationError())) }
        }
    }

    public func disconnect() {
        generation = UUID()
        receiver?.cancel(); receiver = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        for id in Array(pending.keys) { finish(id, result: .failure(MAError.message("Disconnected from Music Assistant."))) }
    }

    private func connectionLost(generation: UUID) {
        guard generation == self.generation else { return }
        disconnect()
        eventContinuation.yield(.object(["event": .string("connection_lost")]))
    }

    private func receive(_ message: JSONValue, generation: UUID) {
        guard generation == self.generation else { return }
        guard let id = message["message_id"].string else {
            eventContinuation.yield(message)
            return
        }
        guard pending[id] != nil else { return }
        if message["error_code"] != .null {
            finish(id, result: .failure(MAError.message(message["details"].string ?? message["error"].string ?? "Music Assistant couldn’t complete this request.")))
        } else if message["partial"].bool == true {
            chunks[id, default: []].append(contentsOf: message["result"].array)
        } else if let previous = chunks[id] {
            finish(id, result: .success(.array(previous + message["result"].array)))
        } else { finish(id, result: .success(message["result"])) }
    }

    private func finish(_ id: String, result: Result<JSONValue, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        chunks.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private static func parse(_ message: URLSessionWebSocketTask.Message) throws -> JSONValue {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw MAError.message("Unsupported server message.")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

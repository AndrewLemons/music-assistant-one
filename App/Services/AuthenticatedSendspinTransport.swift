import Foundation
import MusicAssistantCore
import SendspinKit

/// Authenticates MA's proxy before handing the ordered socket to SendspinKit.
actor AuthenticatedSendspinTransport: SendspinTransport {
    private let socket: URLSessionWebSocketTask
    private(set) var isConnected = false
    private(set) var closeReason: TransportCloseReason?
    init(url: URL) {
        socket = URLSession.shared.webSocketTask(with: url)
    }

    func authenticate(token: String, clientID: String) async throws {
        socket.maximumMessageSize = 8 * 1024 * 1024
        socket.resume()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled {
                socket.cancel(
                    with: .goingAway,
                    reason: nil
                )
            }
        }
        defer { deadline.cancel() }
        let auth = JSONValue.object(["type": .string("auth"), "token": .string(token), "client_id": .string(clientID)])
        try await socket.send(.string(String(decoding: JSONEncoder().encode(auth), as: UTF8.self)))
        guard case let .string(text) = try await socket.receive(),
              let response = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              response["type"].string == "auth_ok"
        else {
            await disconnect()
            throw MAError.message("Music Assistant couldn’t authorize playback on this device.")
        }
        isConnected = true
    }

    func nextFrame() async -> TransportFrame? {
        guard isConnected else { return nil }
        do {
            switch try await socket.receive() {
            case let .string(text): return .text(text)
            case let .data(bytes): return .binary(bytes)
            @unknown default: return nil
            }
        } catch {
            isConnected = false
            closeReason = .failed(description: "The audio connection closed.")
            return nil
        }
    }

    func sendRawText(_ text: String) async throws {
        try await socket.send(.string(text))
    }

    func sendBinary(_ data: Data) async throws {
        try await socket.send(.data(data))
    }

    func disconnect() async {
        isConnected = false
        closeReason = .cancelled
        socket.cancel(with: .goingAway, reason: nil)
    }
}

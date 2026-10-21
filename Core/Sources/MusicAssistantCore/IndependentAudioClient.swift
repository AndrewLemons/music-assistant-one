import Foundation

/// Optional, versioned companion contract. Requests stay on the authenticated server origin.
public struct IndependentAudioClient: Sendable {
    public let server: ServerAddress
    private let token: String
    public init(server: ServerAddress, token: String) {
        self.server = server; self.token = token
    }

    public func isAvailable(session: URLSession = .shared) async throws -> Bool {
        let (data, response) = try await session.data(for: request(path: "one/v1/capabilities"))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 {
            return false
        }
        guard http.statusCode == 200 else { throw Self.failure(status: http.statusCode) }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return value["version"].double == 1 && value["independent_audio"].bool == true
    }

    public func resolve(_ media: MediaItem, session: URLSession = .shared) async throws -> URL {
        var request = request(path: "one/v1/resolve")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["uri": .string(media.uri)]))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        // Tickets can address one audio resource, never arbitrary remote hosts or URL credentials.
        guard let path = value["path"].string, path.hasPrefix("one/v1/audio/"),
              path.hasSuffix(".flac"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let name = path.split(separator: "/").last,
              UUID(uuidString: String(name.dropLast(5))) != nil
        else {
            throw MAError.message("The server returned an invalid audio address.")
        }
        return server.endpoint(path)
    }

    public func audioRequest(for media: MediaItem) throws -> URLRequest {
        var components = URLComponents(url: server.endpoint("one/v1/file.flac"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uri", value: media.uri)]
        guard let url = components.url else { throw URLError(.badURL) }
        var result = request(path: "one/v1/file.flac")
        result.url = url; result.timeoutInterval = 210
        return result
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: server.endpoint(path))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private static func failure(status: Int) -> MAError {
        switch status {
        case 401, 403: .message("Your server didn’t allow audio access. Check your account permissions.")
        case 404: .message("Downloads aren’t available on this server yet. Online playback is still available.")
        case 422: .message("This item can’t be saved for offline listening. Try a song or an album.")
        case 429: .message("Your server is preparing other music. Try again in a moment.")
        case 507: .message("Your server needs more free space to prepare this song.")
        default: .message("Your server couldn’t prepare this song. Try again when it’s reachable.")
        }
    }
}

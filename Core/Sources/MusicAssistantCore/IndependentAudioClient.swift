import Foundation

/// A playable address for one song. Progressive audio is a growing HLS rendition that
/// starts before the server has the complete file; seeking is limited to what has arrived.
public struct ResolvedAudio: Sendable, Equatable {
    public let url: URL
    public let isProgressive: Bool
    public init(url: URL, isProgressive: Bool) {
        self.url = url; self.isProgressive = isProgressive
    }
}

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

    /// Prefers the server's progressive stream unless its complete file is already prepared.
    /// Earlier companions return only the complete file.
    public func resolve(_ media: MediaItem, session: URLSession = .shared) async throws -> ResolvedAudio {
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
        let parts = value["path"].string?.split(separator: "/", omittingEmptySubsequences: false) ?? []
        guard parts.count == 4, parts[0 ... 2] == ["one", "v1", "audio"], parts[3].hasSuffix(".flac"),
              UUID(uuidString: String(parts[3].dropLast(5))) != nil, let path = value["path"].string
        else {
            throw MAError.message("The server returned an invalid audio address.")
        }
        if value["ready"].bool != true, let stream = value["stream"].string {
            let parts = stream.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0 ... 2] == ["one", "v1", "stream"],
                  UUID(uuidString: String(parts[3])) != nil, parts[4] == "index.m3u8"
            else {
                throw MAError.message("The server returned an invalid audio address.")
            }
            return ResolvedAudio(url: server.endpoint(stream), isProgressive: true)
        }
        return ResolvedAudio(url: server.endpoint(path), isProgressive: false)
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

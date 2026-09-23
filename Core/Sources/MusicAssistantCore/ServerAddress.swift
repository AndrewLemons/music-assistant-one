import Foundation

public struct ServerAddress: Sendable, Equatable, Codable {
    public let baseURL: URL
    public init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let local = host.contains(":") || host.hasSuffix(".local") || host == "localhost" || host.split(separator: ".").allSatisfy { Int($0) != nil }
            text = (local ? "http://" : "https://") + text
        }
        guard var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme),
              let host = parts.host, !host.isEmpty, !host.contains(" "),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw MAError.message("Enter a server address, such as https://music.example.com or http://192.168.1.10:8095.")
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw MAError.message("This server address isn’t valid.") }
        baseURL = url
    }
    public func endpoint(_ path: String, websocket: Bool = false) -> URL {
        let url = baseURL.appendingPathComponent(path)
        guard websocket else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return parts.url!
    }
}

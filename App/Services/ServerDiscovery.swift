import Foundation
import Observation

struct DiscoveredServer: Identifiable {
    let id: String
    let name: String
    let address: String
}

@MainActor @Observable
final class ServerDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    var servers: [DiscoveredServer] = []
    var message: String?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    func start() {
        stop()
        message = nil
        browser.delegate = self
        browser.searchForServices(ofType: "_mass._tcp.", inDomain: "local.")
    }
    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        servers.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        servers.removeAll { $0.id == service.name }
        services.removeAll { $0 == service }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName else { return }
        let records = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func value(_ key: String) -> String? { records[key].flatMap { String(data: $0, encoding: .utf8) } }
        let address = value("base_url") ?? "http://\(hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))):\(sender.port)"
        servers.removeAll { $0.id == sender.name }
        servers.append(.init(id: sender.name, name: value("name") ?? "Music Assistant", address: address))
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Nearby servers couldn’t be discovered. You can still enter an address below."
    }
}

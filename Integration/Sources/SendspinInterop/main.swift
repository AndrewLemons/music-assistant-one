import Foundation
import SendspinKit

@main struct SendspinInterop {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2, let base = URL(string: CommandLine.arguments[1]) else {
            throw NSError(domain: "Usage: SendspinInterop http://127.0.0.1:PORT", code: 1)
        }
        var address = URLComponents(url: base.appendingPathComponent("sendspin"), resolvingAgainstBaseURL: false)!
        address.scheme = "ws"
        let identity = SendspinIdentity.generate()
        let psk = Psk.generate()
        let store = InMemoryPairingRecordStore(pairingPsk: psk)
        func client() throws -> SendspinClient {
            try SendspinClient(identity: identity, name: "One interoperability fixture", roles: [.metadataV1, .controllerV1],
                               unpairedAccessEnabled: false, pairing: PairingConfiguration(pairingPsk: psk, store: store))
        }
        let first = try client()
        do {
            try await first.connect(to: address.url!)
            print("PASS: encrypted unpaired handshake")
            var request = URLRequest(url: base.appendingPathComponent("pair"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["token": PairingToken(clientKey: identity.publicKeyBytes, pairingPsk: psk).string])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Pairing rejected", code: 2) }
            let records = await store.listRecords()
            guard records.contains(where: { $0.serverId != nil }) else { throw NSError(domain: "Long-term pairing was not stored", code: 3) }
            print("PASS: account-style PSK pairing and long-term trust record")
            await first.close()
            let second = try client()
            try await second.connect(to: address.url!)
            guard second.connectionState == .connected else { throw NSError(domain: "Reconnect not admitted", code: 4) }
            print("PASS: paired reconnect")
            await second.close()
        } catch {
            await first.close()
            print("FAIL: \(String(reflecting: error))")
            throw error
        }
    }
}

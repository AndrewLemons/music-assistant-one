import Foundation
import MusicAssistantCore
import Security
import SendspinKit

/// Serial, atomic Keychain persistence for the Sendspin revision compatible with MA 2.10.1.
/// Identity, pairing secret, and trust records are one indivisible snapshot.
actor SendspinStateStore: PairingRecordStore, SendspinPersistenceProvider {
    nonisolated let identity: SendspinIdentity
    nonisolated let pairingPSK: Psk
    private var snapshot: Snapshot
    private var storageFailure: String?
    private let onFailure: @Sendable (String) -> Void

    private struct Record: Codable {
        let psk: Data
        let serverId: String?
        var used: Bool
        var value: PairingRecord? {
            guard let key = Psk(bytes: psk) else { return nil }
            return PairingRecord(psk: key, serverId: serverId, used: used)
        }
    }

    private struct Snapshot: Codable {
        var version = 1
        let identitySecret: Data
        let pairingPsk: Data
        var records: [Record]
        var lastPlayedServerId: String?
        var fallbackPskID: String?
    }

    init(onFailure: @escaping @Sendable (String) -> Void) throws {
        self.onFailure = onFailure
        let state: Snapshot
        if let data = try Self.load() {
            state = try JSONDecoder().decode(Snapshot.self, from: data)
        } else {
            let candidate = Snapshot(
                identitySecret: SendspinIdentity.generate().secretKeyBytes,
                pairingPsk: Psk.generate().bytes,
                records: []
            )
            var query = Self.query
            query[kSecValueData as String] = try JSONEncoder().encode(candidate)
            #if !os(macOS) || !DEBUG
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecDuplicateItem, let existing = try Self.load() {
                state = try JSONDecoder().decode(Snapshot.self, from: existing)
            } else {
                guard status == errSecSuccess else { throw Self.failure(status) }
                state = candidate
            }
        }
        guard state.version == 1, let identity = SendspinIdentity(secretKeyBytes: state.identitySecret),
              let psk = Psk(bytes: state.pairingPsk), state.records.allSatisfy({ $0.value != nil })
        else {
            throw MAError.message("The saved player identity is invalid. Its Keychain data was left intact.")
        }
        self.identity = identity; pairingPSK = psk; snapshot = state
    }

    nonisolated var pairingToken: String {
        PairingToken(clientKey: identity.publicKeyBytes, pairingPsk: pairingPSK).string
    }

    func checkHealth() throws {
        if let storageFailure {
            throw MAError.message(storageFailure)
        }
    }

    func listRecords() async -> [PairingRecord] {
        snapshot.records.compactMap(\.value)
    }

    func insert(_ record: PairingRecord) async throws {
        guard record.pskId != pairingPSK.pskId, record.pskId != Psk.sentinel.pskId,
              !snapshot.records.contains(where: { $0.value?.pskId == record.pskId })
        else { throw PairingRecordStoreError.duplicatePskId }
        guard snapshot.records.count < 16 else { throw PairingRecordStoreError.storageExhausted }
        var next = snapshot
        next.records.append(Record(psk: record.psk.bytes, serverId: record.serverId, used: record.used))
        try persist(next)
    }

    func remove(pskId: String) async {
        var next = snapshot
        next.records.removeAll { $0.value?.pskId == pskId }
        saveReportingFailure(next)
    }

    func markUsed(pskId: String) async {
        guard let index = snapshot.records.firstIndex(where: { $0.value?.pskId == pskId }),
              !snapshot.records[index].used else { return }
        var next = snapshot; next.records[index].used = true
        saveReportingFailure(next)
    }

    func ensurePreProvisionedSharedRecord(_ record: PairingRecord) async {
        guard snapshot.fallbackPskID == nil else { return }
        var next = snapshot
        next.records.append(Record(psk: record.psk.bytes, serverId: nil, used: false))
        next.fallbackPskID = record.pskId
        saveReportingFailure(next)
    }

    func loadManagementConfiguration(default configuration: PairingManagementConfiguration) async
        -> PairingManagementConfiguration
    {
        PairingManagementConfiguration(
            pairingPsk: pairingPSK,
            pairingPskEnabled: true,
            recordModePskId: snapshot.fallbackPskID ?? configuration.recordModePskId,
            unpairedAccessEnabled: false
        )
    }

    func saveManagementConfiguration(_: PairingManagementConfiguration) async throws {
        // This app offers playback roles, not device management. Never acknowledge settings
        // mutations which this persistence adapter does not durably implement.
        throw MAError.message("Player security settings are managed by this app.")
    }

    func storageAccounting() async -> PairingStorageAccounting? {
        PairingStorageAccounting(
            free: max(0, 16 - snapshot.records.count),
            capacity: 16,
            costIndividual: 1,
            costShared: 1
        )
    }

    func loadLastPlayedServerId() async -> String? {
        snapshot.lastPlayedServerId
    }

    func saveLastPlayedServerId(_ serverId: String) async {
        guard snapshot.lastPlayedServerId != serverId else { return }
        var next = snapshot; next.lastPlayedServerId = serverId
        saveReportingFailure(next)
    }

    private func persist(_ next: Snapshot) throws {
        let data = try JSONEncoder().encode(next)
        let status = SecItemUpdate(Self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw Self.failure(status) }
        snapshot = next
        storageFailure = nil
    }

    private func saveReportingFailure(_ next: Snapshot) {
        do { try persist(next) }
        catch { storageFailure = error.localizedDescription; onFailure(error.localizedDescription) }
    }

    private static var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "device"]
        #if os(macOS) && DEBUG
            result[kSecAttrService as String] = "app.musicassistant.one.sendspin.mac-development"
        #else
            result[kSecAttrService as String] = "app.musicassistant.one.sendspin"
            result[kSecUseDataProtectionKeychain as String] = true
            result[kSecAttrSynchronizable as String] = false
        #endif
        return result
    }

    private static func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    private static func failure(_ status: OSStatus) -> MAError {
        .message("Couldn’t access this device’s player identity in Keychain (\(status)).")
    }
}

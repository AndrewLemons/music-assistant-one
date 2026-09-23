#if os(macOS) && DEBUG
import Foundation
import Security
import SendspinKit
import MusicAssistantCore

/// Ad-hoc Mac builds have no provisioned application identifier for the data-protection
/// Keychain. Use the login Keychain's app ACL instead. Release/iOS builds use SendspinKit's
/// data-protection store. These namespaces are intentionally distinct.
struct MacDevelopmentDeviceStorage: SendspinDeviceStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.musicassistant.one.sendspin.mac-development",
         kSecAttrAccount as String: "device"]
    }
    func load() async throws -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }
    func create(_ data: Data) async throws -> Bool {
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw failure(status) }
        return true
    }
    func save(_ data: Data) async throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> MAError {
        .message("Couldn’t save this Mac’s player identity in Keychain (\(status)).")
    }
}
#endif

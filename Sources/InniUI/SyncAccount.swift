import Foundation
import InniCore
import Security

/// The AnkiWeb login, kept in the Keychain. The password itself is never stored, only the host key.
struct SyncAccount: Codable, Equatable {
    var username: String
    var auth: SyncAuth

    private static let service = "dev.inni.app.sync"

    static func load() -> SyncAccount? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SyncAccount.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SyncAccount.delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: SyncAccount.service,
                                   kSecAttrAccount as String: username, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

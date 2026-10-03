import Foundation
import Security

enum CredentialStore {
    private static let service = "JellyfinBooks.account"
    static func load() throws -> Account? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecMatchLimit as String: kSecMatchLimitOne, kSecAttrSynchronizable as String: false, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ReaderError.message("Could not read the saved login from Keychain.") }
        let account = try JSONDecoder().decode(Account.self, from: data)
        // Upgrade previously saved entries to foreground-only device-local protection.
        try save(account)
        return account
    }
    static func save(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecAttrSynchronizable as String: false] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrSynchronizable as String] = false
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ReaderError.message("Could not save this login in Keychain.") }
        } else if status != errSecSuccess { throw ReaderError.message("Could not update the saved login.") }
    }
    static func delete() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReaderError.message("Could not remove the saved login.") }
    }
}

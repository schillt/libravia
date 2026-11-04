import Foundation
import Security

/// The injectable boundary lets tests inspect Security queries without reading
/// or changing any real Keychain item.
struct CredentialKeychainBackend {
    var copy: ([String: Any]) -> (OSStatus, CFTypeRef?)
    var update: ([String: Any], [String: Any]) -> OSStatus
    var add: ([String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static var live: Self {
        Self(copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
           add: { SecItemAdd($0 as CFDictionary, nil) },
           delete: { SecItemDelete($0 as CFDictionary) })
    }
}

enum CredentialStore {
    private static let service = "JellyfinBooks.account"
    /// On macOS, this selects the data-protection Keychain instead of the
    /// legacy file-based Keychain, whose ACL may prompt during startup. On iOS
    /// the key is ignored because its Keychain already uses data protection.
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    static func load() throws -> Account? { try load(using: .live) }
    static func load(using backend: CredentialKeychainBackend) throws -> Account? {
        var search = query
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        search[kSecReturnData as String] = true
        let (status, result) = backend.copy(search)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReaderError.message("Could not read the saved login from Keychain.")
        }
        // Reading a saved login never rewrites it. A legacy Mac item is left
        // untouched; the user can reconnect to create a modern credential.
        return try JSONDecoder().decode(Account.self, from: data)
    }

    static func save(_ account: Account) throws { try save(account, using: .live) }
    static func save(_ account: Account, using backend: CredentialKeychainBackend) throws {
        let data = try JSONEncoder().encode(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = backend.update(query, attributes)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            guard backend.add(item) == errSecSuccess else { throw ReaderError.message("Could not save this login in Keychain.") }
        } else if status != errSecSuccess { throw ReaderError.message("Could not update the saved login.") }
    }

    static func delete() throws { try delete(using: .live) }
    static func delete(using backend: CredentialKeychainBackend) throws {
        let status = backend.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ReaderError.message("Could not remove the saved login from Keychain.") }
    }
}

import Foundation
import Security

/// Thin wrapper over the macOS Keychain for the single OpenAI API key.
/// No key is ever written to disk in plaintext or to a .env file.
enum KeychainStore {
    /// The key, once read. Reading the secret can make macOS show an access
    /// prompt (after every rebuild the binary counts as a "new" app), and that
    /// prompt blocks the caller — so read it at most once per launch.
    private static var cached: String?

    /// Whether a key is stored. Reads attributes only, which never prompts —
    /// safe to call at launch.
    static func exists() -> Bool {
        if cached != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: Config.keychainAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func save(_ key: String) {
        cached = key
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: Config.keychainAccount,
        ]
        // Replace any existing item (immutable-style: delete then add).
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load() -> String? {
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: Config.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        cached = key
        return key
    }

    static func clear() {
        cached = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecAttrAccount as String: Config.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

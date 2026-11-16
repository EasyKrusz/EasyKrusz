import Foundation
import Security

/// Klucz API Anthropic trzymany w pęku kluczy (Keychain), współdzielony z rozszerzeniem „Udostępnij”.
enum APIKeyStore {
    private static let service = "pl.easykrusz.przepisy.anthropic"
    private static let account = "api-key"

    private static func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = AppConfig.keychainGroup, !group.hasPrefix("$(") {
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    static var apiKey: String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static var hasKey: Bool { apiKey != nil }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery() as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var q = baseQuery()
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

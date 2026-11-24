import Foundation
import Security

/// Stores the Anthropic API key in the user's login Keychain.
public enum KeychainStore {
    private static let service = "ocr-thai-sub-macos"
    /// Where the key was kept before the project was renamed; moved to `service` on first read.
    private static let oldService = "ps5-thai-subs"
    private static let account = "anthropic-api-key"

    public static func loadAPIKey() -> String? {
        if let key = read(service: service) { return key }
        guard let key = read(service: oldService) else { return nil }
        if saveAPIKey(key) {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: oldService,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
        return key
    }

    private static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

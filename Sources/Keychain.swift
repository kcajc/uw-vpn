import Foundation
import Security

enum PasswordStore {
    private static let service = "net.kcajc.uw-vpn.password"

    private static func query(_ config: Config) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: config.keychainAccount]
    }

    static func read(_ config: Config) throws -> String? {
        var query = query(config)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw VPNError("Keychain returned an unreadable password.")
        }
        return password
    }

    static func save(_ password: String, config: Config) throws {
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(config) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(config).merging(value) { _, new in new }
            item[kSecAttrLabel as String] = "UW VPN — \(config.username)"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    static func forget(_ config: Config) throws {
        let status = SecItemDelete(query(config) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw VPNError("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
}

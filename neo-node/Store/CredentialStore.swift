import Foundation
import Security

/// Keeps the signed-in account (Smart Life session or Cloud project keys) in the login keychain.
enum CredentialStore {
    private static let service = "com.kylswich.neonode"
    private static let account = "tuya-account"

    private static func query(service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var baseQuery: [String: Any] { query() }

    /// The saved login; falls back to the pre-rename (TuyaBar) item and copies it to the current one.
    static func load() -> TuyaAccount? {
        if let account = load(service: service) { return account }
        guard let legacy = load(service: Migration.legacyBundleID) else { return nil }
        do {
            try save(legacy)
        } catch {
            NSLog("neo-node: couldn't copy the login to the keychain: %@", error.localizedDescription)
        }
        return legacy
    }

    /// Reads the login stored under `service`.
    static func load(service: String) -> TuyaAccount? {
        var query = query(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TuyaAccount.self, from: data)
    }

    static func save(_ account: TuyaAccount) throws {
        let data = try JSONEncoder().encode(account)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Where the login is (diagnostics): OSStatus per keychain and service, 0 = found.
    static func diagnostics() -> String {
        var lines: [String] = []
        for service in [service, "com.rahmad.TuyaBar"] {
            for dataProtection in [false, true] {
                var query = query(service: service)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                let decoded = (item as? Data).flatMap { try? JSONDecoder().decode(TuyaAccount.self, from: $0) } != nil
                lines.append("\(service) \(dataProtection ? "data-protection" : "login") → \(status)\(decoded ? " (readable)" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Removes the login, including the pre-rename copy, so a dead session can't come back from it.
    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
        SecItemDelete(query(service: Migration.legacyBundleID) as CFDictionary)
    }
}

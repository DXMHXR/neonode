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

    /// `service` other than the default reads the pre-rename item (migration export).
    static func load(service: String = service) -> TuyaAccount? {
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

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

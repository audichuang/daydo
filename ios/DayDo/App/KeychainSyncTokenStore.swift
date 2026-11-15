import Foundation
import Security
import DayDoCore

/// Keychain-backed `SyncTokenStore` storing access and refresh tokens with
/// `kSecClassGenericPassword` and `kSecAttrAccessibleAfterFirstUnlock`.
final class KeychainSyncTokenStore: SyncTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private let service: String

    private enum Account {
        static let accessToken = "accessToken"
        static let refreshToken = "refreshToken"
    }

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.audichuang.daydo") + ".auth") {
        self.service = service
    }

    var accessToken: String? {
        get { lock.withLock { read(account: Account.accessToken) } }
        set { lock.withLock { write(newValue, account: Account.accessToken) } }
    }

    var refreshToken: String? {
        get { lock.withLock { read(account: Account.refreshToken) } }
        set { lock.withLock { write(newValue, account: Account.refreshToken) } }
    }

    func clearAll() {
        lock.withLock {
            delete(account: Account.accessToken)
            delete(account: Account.refreshToken)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String?, account: String) {
        guard let value, !value.isEmpty else {
            delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

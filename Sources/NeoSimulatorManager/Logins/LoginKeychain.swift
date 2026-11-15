import Foundation
import Security
import Synchronization

/// The keychain items that hold logins, one for each account.
package protocol LoginKeychain: Sendable {
    func accounts() throws -> [String]
    /// The item's data, or `nil` if no item has the account.
    func data(for account: String) throws -> Data?
    func add(_ data: Data, account: String) throws
    /// Replaces an item's data and account together, so that a renamed login is never in two items or in none.
    func update(_ account: String, to data: Data, account newAccount: String) throws
    func delete(_ account: String) throws
}

/// A keychain call that failed, with the status that Security returned.
package struct KeychainFailure: Error, LocalizedError, Equatable {
    package let status: OSStatus

    package init(status: OSStatus) { self.status = status }

    package var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "The keychain returned error \(status)."
    }
}

/// The person's login keychain.
///
/// An item keeps the access that `SecItemAdd` gives it, which trusts the app that added it: that app reads the item
/// without a prompt, and macOS asks the person before another process reads it. An ad hoc signed build can't use
/// the data protection keychain, which needs an entitlement that only a provisioning profile authorizes.
package struct SystemLoginKeychain: LoginKeychain {
    private static let service = "dev.lynnswap.NeoSimulator.Logins"

    package init() {}

    private func query(_ account: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service]
        if let account { query[kSecAttrAccount] = account }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    package func accounts() throws -> [String] {
        var query = query()
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnAttributes] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        return (result as? [[CFString: Any]] ?? []).compactMap { $0[kSecAttrAccount] as? String }
    }

    package func data(for account: String) throws -> Data? {
        var query = query(account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }

    package func add(_ data: Data, account: String) throws {
        var item = query(account)
        item[kSecValueData] = data
        try check(SecItemAdd(item as CFDictionary, nil))
    }

    package func update(_ account: String, to data: Data, account newAccount: String) throws {
        let changes: [CFString: Any] = [kSecAttrAccount: newAccount, kSecValueData: data]
        try check(SecItemUpdate(query(account) as CFDictionary, changes as CFDictionary))
    }

    package func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

#if DEBUG
    /// Holds items in memory so that previews and tests save logins as the app does, without the person's keychain.
    package final class InMemoryLoginKeychain: LoginKeychain {
        /// The items' data, by account.
        package let items = Mutex<[String: Data]>([:])

        package init() {}

        package func accounts() -> [String] { items.withLock { Array($0.keys) } }

        package func data(for account: String) -> Data? { items.withLock { $0[account] } }

        package func add(_ data: Data, account: String) throws {
            try items.withLock {
                guard $0[account] == nil else { throw KeychainFailure(status: errSecDuplicateItem) }
                $0[account] = data
            }
        }

        package func update(_ account: String, to data: Data, account newAccount: String) throws {
            try items.withLock {
                guard $0[account] != nil else { throw KeychainFailure(status: errSecItemNotFound) }
                guard account == newAccount || $0[newAccount] == nil else {
                    throw KeychainFailure(status: errSecDuplicateItem)
                }
                $0[account] = nil
                $0[newAccount] = data
            }
        }

        package func delete(_ account: String) { items.withLock { $0[account] = nil } }
    }
#endif

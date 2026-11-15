import Foundation
import Observation
import Security

/// The logins that a person saved for apps, which the login keychain holds.
@MainActor @Observable
package final class LoginStore {
    package enum Failure: Error, LocalizedError {
        case invalidApplicationIdentifier, emptyLabel, emptyPassword, duplicate, missingLogin

        package var errorDescription: String? {
            switch self {
            case .invalidApplicationIdentifier: "Enter the app’s bundle identifier, such as com.example.app."
            case .emptyLabel: "Enter a label for the login."
            case .emptyPassword: "Enter a password."
            case .duplicate: "The app already has a login with this label."
            case .missingLogin: "This login no longer exists."
            }
        }
    }

    /// The logins that the last read or change left, by app and then by label.
    package private(set) var logins: [SavedLogin] = []
    /// Why the logins couldn't be read.
    package private(set) var issue: String?
    @ObservationIgnored private let keychain: any LoginKeychain
    /// Counts the saves and deletions, so that a read that one of them overtook is read again.
    @ObservationIgnored private var changeCount = 0

    package init(keychain: any LoginKeychain = SystemLoginKeychain()) { self.keychain = keychain }

    /// Reads the logins from the keychain. macOS can ask the person for access, so the read waits off the main actor.
    package func reload() async {
        do {
            var read: [SavedLogin]
            var readAt: Int
            repeat {
                readAt = changeCount
                read = try await readLogins(from: keychain)
            } while readAt != changeCount
            logins = read.sorted(by: Self.precedes)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    /// Saves a login, in place of `existing` if that names one.
    ///
    /// - Parameter password: The password to save, or `nil` to keep the one that `existing` has.
    @discardableResult
    package func save(
        _ login: SavedLogin, password: String?, replacing existing: SavedLogin.ID? = nil
    ) async throws -> SavedLogin {
        var login = login
        login.applicationIdentifier = login.applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        login.label = login.label.trimmingCharacters(in: .whitespacesAndNewlines)
        login.userName = login.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A space separates the identifier from the label in an item's account.
        guard !login.applicationIdentifier.isEmpty, !login.applicationIdentifier.contains(where: \.isWhitespace) else {
            throw Failure.invalidApplicationIdentifier
        }
        guard !login.label.isEmpty else { throw Failure.emptyLabel }
        do {
            try await write(login, password: password, replacing: existing?.account, in: keychain)
        } catch let failure as KeychainFailure where failure.status == errSecDuplicateItem {
            throw Failure.duplicate
        } catch let failure as KeychainFailure where failure.status == errSecItemNotFound {
            throw Failure.missingLogin
        }
        changeCount += 1
        logins.removeAll { $0.id == existing || $0.id == login.id }
        logins.append(login)
        logins.sort(by: Self.precedes)
        return login
    }

    package func delete(_ id: SavedLogin.ID) async throws {
        try await remove(id.account, from: keychain)
        changeCount += 1
        logins.removeAll { $0.id == id }
    }

    private static func precedes(_ first: SavedLogin, _ second: SavedLogin) -> Bool {
        (first.applicationIdentifier, first.label) < (second.applicationIdentifier, second.label)
    }
}

extension SavedLogin.ID {
    /// The account of the keychain item that holds the login.
    fileprivate var account: String { "\(applicationIdentifier) \(label)" }
}

/// What a keychain item's data holds. Everything that decides where a login is typed is in the data, which only
/// this app reads without a prompt, so that another process can't point a saved password at another app or origin
/// by changing an item's attributes.
private struct LoginRecord: Codable {
    var applicationIdentifier: String
    var label: String
    var userName: String
    var password: String
    var origins: [WebOrigin]
    var allowsAutomation: Bool

    init(_ login: SavedLogin, password: String) {
        applicationIdentifier = login.applicationIdentifier
        label = login.label
        userName = login.userName
        self.password = password
        origins = login.origins
        allowsAutomation = login.allowsAutomation
    }

    var login: SavedLogin {
        SavedLogin(
            applicationIdentifier: applicationIdentifier, label: label, userName: userName, origins: origins,
            allowsAutomation: allowsAutomation)
    }
}

@concurrent private func readLogins(from keychain: any LoginKeychain) async throws -> [SavedLogin] {
    try keychain.accounts().compactMap { account in
        // An item whose data names another login than its account does isn't one that this app saved.
        guard let data = try keychain.data(for: account),
            let login = try? JSONDecoder().decode(LoginRecord.self, from: data).login, login.id.account == account
        else { return nil }
        return login
    }
}

@concurrent private func write(
    _ login: SavedLogin, password: String?, replacing existing: String?, in keychain: any LoginKeychain
) async throws {
    var password = password.flatMap { $0.isEmpty ? nil : $0 }
    if let existing, password == nil {
        guard let data = try keychain.data(for: existing) else { throw LoginStore.Failure.missingLogin }
        password = try JSONDecoder().decode(LoginRecord.self, from: data).password
    }
    guard let password else { throw LoginStore.Failure.emptyPassword }
    let data = try JSONEncoder().encode(LoginRecord(login, password: password))
    if let existing {
        try keychain.update(existing, to: data, account: login.id.account)
    } else {
        try keychain.add(data, account: login.id.account)
    }
}

@concurrent private func remove(_ account: String, from keychain: any LoginKeychain) async throws {
    try keychain.delete(account)
}

import Foundation
import NeoSimulatorDeviceIO
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

    package init(keychain: any LoginKeychain = SystemLoginKeychain()) { self.keychain = keychain }

    /// The read or change that was asked for last, which the next one waits for.
    @ObservationIgnored private var lastOperation: Task<Void, Never>?

    // A keychain call waits for as long as macOS asks the person for access, so each one runs as blocking I/O.
    // Each read or change leaves `logins` as the keychain was when it ran, so they run one at a time, in the order
    // that their callers asked for them: the Logins pane, the menu's list and a sign-in share the store.
    private func inTurn<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        lastOperation = Task { _ = await task.result }
        return try await task.value
    }

    /// Reads the logins from the keychain.
    package func reload() async {
        // The read's result is taken in its turn too, so that a change that follows it is not undone by it.
        try? await inTurn { [self, keychain] in
            do {
                logins = try await performBlockingIO { try readLogins(from: keychain) }.sorted(by: Self.precedes)
                issue = nil
            } catch {
                issue = error.localizedDescription
            }
        }
    }

    /// A login with its password, as the keychain holds them when it is asked. A sign-in reads what it fills in from
    /// here, and `logins` keeps no password.
    package func credentials(for id: SavedLogin.ID) async throws -> (login: SavedLogin, password: String) {
        try await inTurn { [keychain] in
            try await performBlockingIO {
                guard let record = try record(for: id.account, in: keychain) else { throw Failure.missingLogin }
                return (record.login, record.password)
            }
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
        return try await inTurn { [self, keychain, login] in
            do {
                try await performBlockingIO {
                    try write(login, password: password, replacing: existing?.account, in: keychain)
                }
            } catch let failure as KeychainFailure where failure.status == errSecDuplicateItem {
                throw Failure.duplicate
            } catch let failure as KeychainFailure where failure.status == errSecItemNotFound {
                throw Failure.missingLogin
            }
            logins.removeAll { $0.id == existing || $0.id == login.id }
            logins.append(login)
            logins.sort(by: Self.precedes)
            return login
        }
    }

    package func delete(_ id: SavedLogin.ID) async throws {
        try await inTurn { [self, keychain] in
            try await performBlockingIO { try keychain.delete(id.account) }
            logins.removeAll { $0.id == id }
        }
    }

    private static func precedes(_ first: SavedLogin, _ second: SavedLogin) -> Bool {
        (first.applicationIdentifier, first.label) < (second.applicationIdentifier, second.label)
    }
}

extension SavedLogin.ID {
    /// The account of the keychain item that holds the login.
    fileprivate var account: String { "\(applicationIdentifier) \(label)" }
}

/// What a keychain item's data holds. Everything that decides where a login is used is in the data, which only
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

/// What the item for `account` holds, or `nil` if the keychain has no login there. An item whose data names another
/// login than its account does isn't one that this app saved, whatever moved it there.
private func record(for account: String, in keychain: any LoginKeychain) throws -> LoginRecord? {
    guard let data = try keychain.data(for: account),
        let record = try? JSONDecoder().decode(LoginRecord.self, from: data), record.login.id.account == account
    else { return nil }
    return record
}

private func readLogins(from keychain: any LoginKeychain) throws -> [SavedLogin] {
    try keychain.accounts().compactMap { try record(for: $0, in: keychain)?.login }
}

private func write(
    _ login: SavedLogin, password: String?, replacing existing: String?, in keychain: any LoginKeychain
) throws {
    var password = password.flatMap { $0.isEmpty ? nil : $0 }
    if let existing, password == nil {
        guard let record = try record(for: existing, in: keychain) else { throw LoginStore.Failure.missingLogin }
        password = record.password
    }
    guard let password else { throw LoginStore.Failure.emptyPassword }
    let data = try JSONEncoder().encode(LoginRecord(login, password: password))
    if let existing {
        try keychain.update(existing, to: data, account: login.id.account)
    } else {
        try keychain.add(data, account: login.id.account)
    }
}

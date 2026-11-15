import Foundation
@testable import NeoSimulatorApp
@testable import NeoSimulatorManager
import Synchronization
import Testing

extension ManagerModelTests {
    /// The password that the keychain item for `account` holds.
    private func savedPassword(_ account: String, in keychain: InMemoryLoginKeychain) throws -> String? {
        let data = try #require(keychain.data(for: account))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])["password"] as? String
    }

    @Test func savingALoginKeepsItInOneKeychainItemAndAnEditKeepsItsPassword() async throws {
        let keychain = InMemoryLoginKeychain()
        let model = LoginsSettingsModel(store: LoginStore(keychain: keychain))
        model.add()
        model.draft?.applicationIdentifier = " com.example.app "
        model.draft?.label = "Premium"
        model.draft?.userName = "premium@example.com"
        model.draft?.password = "s3cret"
        model.draft?.origins = "login.example.com, http://localhost:3000"
        model.save()
        await model.operation?.value

        let origins = try [#require(WebOrigin("https://login.example.com")), #require(WebOrigin("http://localhost:3000"))]
        var login = SavedLogin(
            applicationIdentifier: "com.example.app", label: "Premium", userName: "premium@example.com",
            origins: origins)
        #expect(model.draft == nil && model.selection == login.id)
        #expect(model.store.logins == [login])
        #expect(keychain.accounts() == ["com.example.app Premium"])
        #expect(try savedPassword("com.example.app Premium", in: keychain) == "s3cret")

        model.edit(login.id)
        #expect(model.draft?.password == "" && model.draft?.origins == "https://login.example.com, http://localhost:3000")
        model.draft?.label = "Free"
        model.draft?.allowsAutomation = false
        model.save()
        await model.operation?.value

        login.label = "Free"
        login.allowsAutomation = false
        #expect(model.draft == nil && model.selection == login.id)
        #expect(keychain.accounts() == ["com.example.app Free"])
        #expect(try savedPassword("com.example.app Free", in: keychain) == "s3cret")
        let reopened = LoginStore(keychain: keychain)
        await reopened.reload()
        #expect(reopened.logins == [login] && reopened.issue == nil)

        model.delete(login)
        await model.operation?.value
        #expect(model.store.logins.isEmpty && keychain.accounts().isEmpty)
    }

    @Test func aSecondLoginWithAnAppsLabelStaysInTheEditorAndLeavesTheFirst() async throws {
        let keychain = InMemoryLoginKeychain()
        let model = LoginsSettingsModel(store: LoginStore(keychain: keychain))
        for password in ["first", "second"] {
            model.add()
            model.draft?.applicationIdentifier = "com.example.app"
            model.draft?.label = "Premium"
            model.draft?.password = password
            model.save()
        await model.operation?.value
        }
        #expect(model.draft?.issue == LoginStore.Failure.duplicate.localizedDescription)
        #expect(model.store.logins.count == 1)
        #expect(try savedPassword("com.example.app Premium", in: keychain) == "first")
    }

    @Test func anItemMovedToAnotherAppsAccountIsNotALogin() async throws {
        let keychain = InMemoryLoginKeychain()
        let store = LoginStore(keychain: keychain)
        try await store.save(
            SavedLogin(applicationIdentifier: "com.example.app", label: "Premium", userName: "premium@example.com"),
            password: "s3cret")
        keychain.items.withLock { items in
            items["com.example.other Premium"] = items.removeValue(forKey: "com.example.app Premium")
        }
        await store.reload()
        #expect(store.logins.isEmpty && store.issue == nil)
    }

    @Test func thePaneFinishesOneKeychainOperationBeforeItStartsAnother() async throws {
        let model = LoginsSettingsModel(store: LoginStore(keychain: InMemoryLoginKeychain()))
        model.reload()
        model.add()
        #expect(model.isBusy && model.draft == nil)
        await model.operation?.value
        model.add()
        model.draft?.applicationIdentifier = "com.example.app"
        model.draft?.label = "Premium"
        model.draft?.password = "s3cret"
        model.save()
        await model.operation?.value
        let login = try #require(model.store.logins.first)

        model.delete(login)
        model.edit(login.id)
        #expect(model.isBusy && model.draft == nil)
        await model.operation?.value
        #expect(!model.isBusy && model.store.logins.isEmpty)
    }

    @Test func webOriginsReadASchemeAHostAndAPort() throws {
        #expect(WebOrigin("Example.com")?.text == "https://example.com")
        #expect(WebOrigin("https://example.com:443/") == WebOrigin("example.com"))
        #expect(WebOrigin("http://localhost:3000")?.port == 3000)
        #expect(WebOrigin("http://[::1]:3000")?.text == "http://[::1]:3000")
        for text in ["https://example.com/login", "ftp://example.com", "https://user@example.com", "https://"] {
            #expect(WebOrigin(text) == nil, "\(text)")
        }
        #expect(throws: WebOrigin.Invalid.self) { try WebOrigin.list(from: "example.com, https://example.com/login") }
    }
}

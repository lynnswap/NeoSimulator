import AppKit
import Foundation
@testable import NeoSimulatorApp
import NeoSimulatorDeviceIO
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

    @Test func anEditDoesNotKeepThePasswordOfAnItemMovedToItsAccount() async throws {
        let keychain = InMemoryLoginKeychain()
        let store = LoginStore(keychain: keychain)
        let login = try await store.save(
            SavedLogin(applicationIdentifier: "com.example.app", label: "Premium", userName: "premium@example.com"),
            password: "s3cret")
        try await store.save(
            SavedLogin(applicationIdentifier: "com.example.other", label: "Premium", userName: "other@example.com"),
            password: "other")
        let moved = keychain.items.withLock { items in
            items["com.example.app Premium"] = items.removeValue(forKey: "com.example.other Premium")
            return items["com.example.app Premium"]
        }
        await #expect(throws: LoginStore.Failure.missingLogin) {
            try await store.save(login, password: nil, replacing: login.id)
        }
        #expect(keychain.data(for: "com.example.app Premium") == moved)
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

    @Test func theStoreRunsWhatItIsAskedInOrderAndReturnsALoginWithItsPassword() async throws {
        let store = LoginStore(keychain: InMemoryLoginKeychain())
        let login = SavedLogin(
            applicationIdentifier: "com.example.app", label: "Premium", userName: "premium@example.com",
            origins: try [#require(WebOrigin("https://login.example.com"))])
        // The read was asked for while the save had not yet written, and still finds what the save wrote.
        let saving = Task { try await store.save(login, password: "s3cret") }
        let reading = Task { try await store.credentials(for: login.id) }
        _ = try await saving.value
        let credentials = try await reading.value
        #expect(credentials.login == login && credentials.password == "s3cret")

        try await store.delete(login.id)
        await #expect(throws: LoginStore.Failure.missingLogin) { try await store.credentials(for: login.id) }
    }

    private func premium(
        userName: String = "premium@example.com", origins: [String], script: String? = nil, signInButton: String = ""
    ) -> SavedLogin {
        SavedLogin(
            applicationIdentifier: "com.example.app", label: "Premium", userName: userName,
            origins: origins.map { WebOrigin($0)! }, webSignIn: script == nil ? .automatic : .script,
            script: script ?? "", signInButton: signInButton)
    }

    /// A sign-in that looks often and does not wait long, for a device that answers at once.
    private func signIn(
        on device: SignInFixture, userName: String = "premium@example.com",
        origins: [String] = ["https://login.example.com"], script: String? = nil, signInButton: String = ""
    ) -> WebAuthenticationSignIn {
        var pace = WebAuthenticationSignIn.Pace()
        pace.appearance = .milliseconds(100)
        pace.completion = .milliseconds(100)
        pace.button = .milliseconds(100)
        pace.interval = .milliseconds(5)
        pace.tapAgain = .milliseconds(20)
        return WebAuthenticationSignIn(
            device: device,
            login: premium(userName: userName, origins: origins, script: script, signInButton: signInButton),
            password: "s3cret", pace: pace)
    }

    @Test func aLoginsOwnScriptRunsOnceInEachPageAtItsOriginsUntilTheSheetCloses() async throws {
        let origins = ["https://login.example.com", "https://sso.example.org"]
        func own(_ origin: String) -> SignInScript {
            .own(script: "sign()", userName: "premium@example.com", password: "s3cret", origin: origin)
        }
        /// A sign-in with the login's own script that starts on a page which the built-in filling does not recognize,
        /// and which `next` follows once the script has run.
        func signedIn(then next: [SignInPageState]) async -> (failure: (any Error)?, scripts: [SignInScript]) {
            let device = SignInFixture()
            device.front = SignInFixture.application("com.example.app")
            device.page = SignInPageState(origin: "https://login.example.com", step: nil, document: "1", path: "/login")
            var next = next
            device.onSubmit = { device.page = next.isEmpty ? nil : next.removeFirst() }
            var failure: (any Error)?
            do { try await signIn(on: device, origins: origins, script: "sign()").run() } catch { failure = error }
            return (failure, device.scripts.filter { $0 != .state })
        }

        // The second page is another document at another of the login's origins, and the sheet closes after it.
        let password = SignInPageState(origin: "https://sso.example.org", step: nil, document: "2", path: "/password")
        var ended = await signedIn(then: [password])
        #expect(ended.failure == nil && ended.scripts == [own("https://login.example.com"), own("https://sso.example.org")])

        // The first page loads again: the site did not take what the script submitted, and it is not submitted again.
        let again = SignInPageState(origin: "https://login.example.com", step: nil, document: "2", path: "/login")
        ended = await signedIn(then: [again])
        #expect(ended.failure as? WebAuthenticationSignIn.Failure == .rejected)
        #expect(ended.scripts == [own("https://login.example.com"), .clear(origin: "https://login.example.com")])

        // The script does not run in a page at an origin that the login does not list.
        let other = SignInPageState(origin: "https://other.example", step: nil, document: "2", path: "/password")
        ended = await signedIn(then: [other])
        #expect(ended.failure as? WebAuthenticationSignIn.Failure == .unrecognizedPage(origin: "https://other.example"))
        #expect(ended.scripts.count { if case .own = $0 { true } else { false } } == 1)
    }

    @Test func aLoginKeepsItsScriptInTheKeychainAndAnOlderItemSignsInAutomatically() async throws {
        let keychain = InMemoryLoginKeychain()
        let store = LoginStore(keychain: keychain)
        var login = premium(origins: ["https://login.example.com"], script: "sign()", signInButton: "#signIn")
        try await store.save(login, password: "s3cret")
        await store.reload()
        #expect(store.logins == [login])
        // A login that signs in with its own script has one.
        login.script = "  "
        await #expect(throws: LoginStore.Failure.emptyScript) {
            try await store.save(login, password: nil, replacing: login.id)
        }

        // An item from before a login could have a script.
        let older = """
            {"applicationIdentifier": "com.example.app", "label": "Older", "userName": "older@example.com",
             "password": "s3cret", "origins": [], "allowsAutomation": true}
            """
        try keychain.add(Data(older.utf8), account: "com.example.app Older")
        await store.reload()
        #expect(store.logins.first { $0.label == "Older" }?.webSignIn == .automatic)
    }

    @Test func aSignInFillsTheAppsOwnFormPressesItsButtonAndWaitsForTheFormToGo() async throws {
        func element(
            _ role: SimulatorAccessibilityElement.Role, _ identifier: String, label: String? = nil, value: String? = nil,
            isEnabled: Bool = true, row: CGFloat, process: Int32 = 5
        ) -> SimulatorAccessibilityElement {
            SimulatorAccessibilityElement(
                role: role, isSecureTextField: identifier.hasPrefix("password"), isEnabled: isEnabled, label: label,
                value: value, identifier: identifier, frame: CGRect(x: 16, y: 300 + row * 50, width: 370, height: 34),
                processIdentifier: process)
        }
        /// The app with elements of its own.
        func application(_ children: [SimulatorAccessibilityElement]) -> SimulatorAccessibilityElement {
            var application = SignInFixture.application("com.example.app")
            application.children = children
            return application
        }
        /// The app's sign-in screen, where a button that does not sign in comes before the one that does. The app
        /// enables the button that signs in once the form has a password.
        func form(userName: String = "", password: String = "", enables: Bool = true) -> SimulatorAccessibilityElement {
            application([
                element(.textField, "user", value: userName.isEmpty ? "Email" : userName, row: 0),
                element(
                    .textField, "password", value: password.isEmpty ? "Password" : String(repeating: "•", count: password.count),
                    row: 1),
                element(.button, "forgot", label: "Forgot password?", row: 2),
                element(.button, "signIn", label: "Sign In", isEnabled: enables && !password.isEmpty, row: 3),
            ])
        }
        let home = application([element(.staticText, "welcome", label: "Welcome", row: 0)])

        /// The identifier of the button that a login presses on a screen.
        func button(_ name: String, on screen: SimulatorAccessibilityElement) throws -> String? {
            let elements = NativeFormSignIn.elements(of: screen)
            return try NativeFormSignIn.form(among: elements, button: name).flatMap { elements[$0.button].identifier }
        }
        // The button is the first after the password field, or the one that the login names by label or identifier.
        #expect(try button("", on: form()) == "forgot")
        #expect(try button("Sign In", on: form()) == "signIn")
        #expect(try button("#signIn", on: form()) == "signIn")
        #expect(try button("", on: home) == nil)
        // A screen with two password fields registers an account or changes a password.
        var registration = form()
        registration.children.append(element(.textField, "passwordAgain", row: 4))
        #expect(throws: NativeFormSignIn.Failure.severalPasswordFields) { try button("", on: registration) }
        // A password field of another process, as of one that renders a web page, is not the app's form.
        #expect(try button("", on: application([element(.textField, "password", row: 0, process: 9)])) == nil)

        /// How a sign-in ends on the app's form, which shows `shown` once its button is pressed, and what it did.
        func signedIn(
            button: String = "Sign In", enables: Bool = true, then shown: @escaping (SignInFixture) -> Void
        ) async -> (failure: (any Error)?, actions: [String]) {
            let device = SignInFixture()
            var (userName, password) = ("", "")
            device.front = form()
            device.onAction = { action, element in
                switch action {
                case .setValue(let value) where element.identifier == "user": userName = value
                case .setValue(let value): password = value
                case .press: return shown(device)
                }
                // A field that gets a value brings up the keyboard, which moves the form.
                var moved = form(userName: userName, password: password, enables: enables)
                for index in moved.children.indices { moved.children[index].frame.origin.y -= 150 }
                device.covered = moved
                if device.front?.children.first?.identifier == "user" { device.front = moved }
            }
            var failure: (any Error)?
            do { try await signIn(on: device, signInButton: button).run() } catch { failure = error }
            return (failure, device.actions)
        }
        let filled = ["set user to premium@example.com", "set password to s3cret"]

        var ended = await signedIn { device in (device.front, device.covered) = (home, home) }
        #expect(ended.failure == nil && ended.actions == filled + ["press signIn"])

        // An alert that says why the login was not taken covers the form, which the app still has under it, now
        // without its buttons. What was filled in does not stay there.
        ended = await signedIn { device in
            device.front = application([element(.staticText, "alert", label: "Wrong password", row: 1)])
            device.covered?.children.removeAll { $0.role == .button }
        }
        #expect(ended.failure as? NativeFormSignIn.Failure == .rejected)
        #expect(ended.actions == filled + ["press signIn", "set password to ", "set user to "])

        // The app keeps its button disabled: a press would do nothing, so the button is not pressed.
        ended = await signedIn(enables: false) { _ in }
        #expect(ended.failure as? NativeFormSignIn.Failure == .buttonUnavailable)
        #expect(ended.actions == filled + ["set password to ", "set user to "])

        // The login names a button that the screen does not have: nothing is filled in.
        ended = await signedIn(button: "Log In") { _ in }
        #expect(
            ended.failure as? NativeFormSignIn.Failure == .noButton(named: "Log In", buttons: ["#forgot", "#signIn"]))
        #expect(ended.actions.isEmpty)
    }

    @Test func aSignInGoesOnFromTheUserNamesPageToThePasswordsPageAtAnotherOfItsOrigins() async throws {
        let device = SignInFixture()
        device.front = SignInFixture.application("com.example.app")
        device.page = SignInPageState(origin: "https://login.example.com", step: .userName, document: "1")
        // The page enables its button once it has looked at the user name.
        device.disabledButtonReads = 2
        // The password's page is another document, on another host that the login lists. The sheet closes after it.
        var pages = [SignInPageState(origin: "https://sso.example.org", step: .password, document: "2")]
        device.onSubmit = { device.page = pages.isEmpty ? nil : pages.removeFirst() }
        try await signIn(on: device, origins: ["https://login.example.com", "https://sso.example.org"]).run()
        #expect(
            device.scripts.filter { $0 != .state } == [
                .signIn(userName: "premium@example.com", password: "s3cret", origin: "https://login.example.com"),
                .submit(origin: "https://login.example.com"), .submit(origin: "https://login.example.com"),
                .signIn(userName: "premium@example.com", password: "s3cret", origin: "https://sso.example.org"),
            ])
    }

    @Test func aSignInStopsAfterTheUserNameWhereThePageThatFollowsIsNotItsOwn() async throws {
        /// How a sign-in ends that starts on the user name's page, which `next` follows, and how many pages it filled.
        func outcome(
            userName: String = "premium@example.com", then next: SignInPageState?
        ) async -> (failure: WebAuthenticationSignIn.Failure?, filled: Int) {
            let device = SignInFixture()
            device.front = SignInFixture.application("com.example.app")
            device.page = SignInPageState(origin: "https://login.example.com", step: .userName, document: "1")
            device.onSubmit = { device.page = next }
            var failure: WebAuthenticationSignIn.Failure?
            do { try await signIn(on: device, userName: userName).run() } catch {
                failure = error as? WebAuthenticationSignIn.Failure
            }
            return (failure, device.scripts.count { if case .signIn = $0 { true } else { false } })
        }
        // The password's page is on a host that the login does not list: the password is not filled in there.
        var ended = await outcome(then: SignInPageState(origin: "https://other.example", step: .password, document: "2"))
        #expect(ended.failure == .unrecognizedPage(origin: "https://other.example") && ended.filled == 1)
        // The user name's page loaded again.
        ended = await outcome(then: SignInPageState(origin: "https://login.example.com", step: .userName, document: "2"))
        #expect(ended.failure == .rejected && ended.filled == 1)
        // The sheet closed after the user name, as where the site already knows the person.
        ended = await outcome(then: nil)
        #expect(ended.failure == nil && ended.filled == 1)
        // A login without a user name has nothing for the page.
        let device = SignInFixture()
        device.front = SignInFixture.application("com.example.app")
        device.page = SignInPageState(origin: "https://login.example.com", step: .userName, document: "1")
        await #expect(throws: WebAuthenticationSignIn.Failure.unrecognizedPage(origin: "https://login.example.com")) {
            try await signIn(on: device, userName: "").run()
        }
    }

    @Test func aSignInAcceptsItsSitesConsentFillsThePageAtItsOriginAndDeclinesToSaveThePassword() async throws {
        /// The taps of a sign-in whose sheet offers to save the password with `offer`'s buttons, and its scripts.
        func signedIn(offering offer: [CGRect]) async throws -> SignInFixture {
            let device = SignInFixture()
            device.front = SignInFixture.consentAlert(naming: "login.example.com")
            // The first tap reaches an alert that is still coming up, which ignores it.
            device.onTap = {
                switch device.taps.count {
                case 2:
                    device.front = SignInFixture.application("com.example.app")
                    device.page = SignInPageState(origin: "https://login.example.com", step: .password, document: "1")
                case 3:
                    // The sheet closes once its offer is answered.
                    device.offer = []
                    device.page = nil
                default: break
                }
            }
            device.onSubmit = { device.offer = offer }
            try await signIn(on: device).run()
            return device
        }

        // The alert's trailing button continues. Of three stacked choices, the lowest declines.
        let stacked = [400, 460, 520].map { CGRect(x: 50, y: $0, width: 300, height: 48) }
        var device = try await signedIn(offering: stacked)
        #expect(device.taps == [CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.5, y: 0.68)])
        #expect(
            device.scripts.filter { $0 != .state }
                == [.signIn(userName: "premium@example.com", password: "s3cret", origin: "https://login.example.com")])

        // Of two choices side by side, the leading one declines.
        device = try await signedIn(offering: [CGRect(x: 40, y: 520, width: 140, height: 48), CGRect(x: 220, y: 520, width: 140, height: 48)])
        #expect(device.taps.last == CGPoint(x: 0.275, y: 0.68))
    }

    @Test func aSignInFillsNothingForAnotherAppAnotherSiteOrAPageThatIsOffTheScreen() async throws {
        func refused(_ arrange: (SignInFixture) -> Void) async -> WebAuthenticationSignIn.Failure? {
            let device = SignInFixture()
            arrange(device)
            var failure: WebAuthenticationSignIn.Failure?
            do { try await signIn(on: device).run() } catch { failure = error as? WebAuthenticationSignIn.Failure }
            #expect(device.taps.isEmpty && device.scripts.allSatisfy { $0 == .state })
            return failure
        }
        #expect(await refused { $0.front = SignInFixture.application("com.example.other") } == .otherApplication("com.example.other"))
        // The alert asks for another site, whose name only contains the login's.
        #expect(await refused { $0.front = SignInFixture.consentAlert(naming: "login.example.com.other.example") } == .otherApplication(nil))
        #expect(
            await refused {
                $0.front = SignInFixture.application("com.example.app")
                $0.page = SignInPageState(origin: "https://other.example", step: .password)
            } == .unrecognizedPage(origin: "https://other.example"))
        // A sheet that closed leaves its page listed.
        #expect(
            await refused {
                $0.front = SignInFixture.application("com.example.app")
                $0.page = SignInPageState(origin: "https://login.example.com", isVisible: false, step: .password)
            } == .noSheet)
    }

    @Test func aSignInThatDoesNotCloseTheSheetSaysWhyAndLeavesNoPassword() async throws {
        func outcome(after submit: @escaping (SignInFixture) -> Void) async -> WebAuthenticationSignIn.Failure? {
            let device = SignInFixture()
            device.front = SignInFixture.application("com.example.app")
            device.page = SignInPageState(origin: "https://login.example.com", step: .password, document: "1")
            device.onSubmit = { submit(device) }
            var failure: WebAuthenticationSignIn.Failure?
            do { try await signIn(on: device).run() } catch { failure = error as? WebAuthenticationSignIn.Failure }
            #expect(device.scripts.last == .clear(origin: "https://login.example.com"))
            return failure
        }
        // The sign-in page loaded again.
        #expect(await outcome { $0.page?.document = "2" } == .rejected)
        // The page showed its answer without loading again.
        #expect(await outcome { _ in } == .rejected)
        // The tool that asked went away while the sheet was still open.
        let waiting = SignInFixture()
        waiting.front = SignInFixture.application("com.example.app")
        waiting.page = SignInPageState(origin: "https://login.example.com", step: .password, document: "1")
        let (submissions, submitted) = AsyncStream.makeStream(of: Void.self)
        waiting.onSubmit = { submitted.yield() }
        let abandoned = Task { try await signIn(on: waiting).run() }
        for await _ in submissions { break }
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(waiting.scripts.last == .clear(origin: "https://login.example.com"))

        // The sheet went on to a page that is not the login's, such as one that asks for a code.
        #expect(
            await outcome { $0.page = SignInPageState(origin: "https://codes.example", step: nil) }
                == .unrecognizedPage(origin: "https://codes.example"))
    }

    @Test func theConsentAlertsLeadingButtonContinuesOnADeviceThatReadsFromRightToLeft() {
        let alert = SignInFixture.consentAlert(naming: "login.example.com", message: "يريد “App” استخدام “login.example.com”")
        let button = WebAuthenticationSignIn.consentButton(in: alert, hosts: ["login.example.com"])
        #expect(button?.frame.midX == 100)
    }

    @Test func theDeviceMenuListsTheSavedLoginsUnderTheirApps() async throws {
        // The menu asks the app for its key window.
        _ = NSApplication.shared
        let store = LoginStore(keychain: InMemoryLoginKeychain())
        let menu = SignInMenu(logins: store)
        menu.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["No Saved Logins"] && menu.items.allSatisfy { !$0.isEnabled })

        for (application, label) in [("com.example.b", "Free"), ("com.example.a", "Premium"), ("com.example.a", "Free")] {
            try await store.save(
                SavedLogin(applicationIdentifier: application, label: label, userName: "", origins: []), password: "s3cret")
        }
        menu.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["com.example.a", "Free", "Premium", "com.example.b", "Free"])
        #expect(
            menu.items.compactMap { $0.representedObject as? SavedLogin.ID }.map(\.applicationIdentifier)
                == ["com.example.a", "com.example.a", "com.example.b"])
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

/// A device as a sign-in sees it: what is in front, and the page of the app's web authentication sheet.
@MainActor
private final class SignInFixture: SignInDevice {
    static let sheet = InspectablePage(
        application: "PID:7", bundleIdentifier: "com.apple.SafariViewService", identifier: 1, url: "", title: "")
    private static let screen = CGRect(x: 0, y: 0, width: 400, height: 800)

    var front: SimulatorAccessibilityElement?
    /// The sheet's page, or nil while the device lists none.
    var page: SignInPageState?
    var onTap: (() -> Void)?
    /// Runs when the sign-in's script has filled the page's form and submitted it.
    var onSubmit: (() -> Void)?
    /// How many times the form's button is still disabled when the sign-in tries to press it after filling the form.
    var disabledButtonReads = 0
    private var isFilled = false
    private(set) var taps: [CGPoint] = []
    private(set) var scripts: [SignInScript] = []

    /// An app in front. While its sheet is up, it has no elements of its own.
    static func application(_ identifier: String) -> SimulatorAccessibilityElement {
        SimulatorAccessibilityElement(role: .application, frame: screen, processIdentifier: 5, bundleIdentifier: identifier)
    }

    /// The system's alert that asks whether an app may sign in with a site.
    static func consentAlert(naming host: String, message: String? = nil) -> SimulatorAccessibilityElement {
        func element(_ role: SimulatorAccessibilityElement.Role, _ label: String, x: CGFloat) -> SimulatorAccessibilityElement {
            SimulatorAccessibilityElement(
                role: role, label: label, frame: CGRect(x: x, y: 380, width: 160, height: 40), processIdentifier: 1)
        }
        return SimulatorAccessibilityElement(
            role: .application, frame: screen, processIdentifier: 1, bundleIdentifier: "com.apple.springboard",
            children: [
                element(.staticText, message ?? "“App” Wants to Use “\(host)” to Sign In", x: 20),
                element(.button, "Cancel", x: 20), element(.button, "Continue", x: 220),
            ])
    }

    func frontmostApplication() async throws -> SimulatorAccessibilityElement? { front }

    /// The buttons of the sheet's offer to save the password, while it shows. They belong to the sheet's process.
    var offer: [CGRect] = []

    func element(at point: CGPoint) async throws -> SimulatorAccessibilityElement? {
        offer.first { $0.contains(point) }.map { SimulatorAccessibilityElement(role: .button, frame: $0, processIdentifier: 7) }
    }

    /// The login's app as its process answers for its elements, also while an alert covers them. Without it, as `front`.
    var covered: SimulatorAccessibilityElement?
    /// Runs when an element takes an action.
    var onAction: ((SimulatorAccessibilityAction, SimulatorAccessibilityElement) -> Void)?
    /// The actions that elements took, each with its element's identifier.
    private(set) var actions: [String] = []

    func application(ofProcess processIdentifier: Int32) async throws -> SimulatorAccessibilityElement? {
        covered ?? front
    }

    func perform(
        _ action: SimulatorAccessibilityAction, inProcess processIdentifier: Int32,
        on choose: @escaping @Sendable ([SimulatorAccessibilityElement]) -> Int?
    ) async throws {
        try Task.checkCancellation()
        let elements = (covered ?? front).map(NativeFormSignIn.elements) ?? []
        guard let chosen = choose(elements) else { throw SimulatorAccessibilityActionFailure.elementGone }
        let element = elements[chosen]
        switch action {
        case .press: actions.append("press \(element.identifier ?? "")")
        case .setValue(let value): actions.append("set \(element.identifier ?? "") to \(value)")
        }
        onAction?(action, element)
    }

    func pages() async throws -> [InspectablePage] { page == nil ? [] : [Self.sheet] }

    func run(_ script: SignInScript, in page: InspectablePage) async throws -> SignInPageState {
        // As the Web Inspector does, a cancelled task runs no script.
        try Task.checkCancellation()
        scripts.append(script)
        var state = try #require(self.page)
        if case .signIn(let userName, _, let origin) = script, origin == state.origin, state.isVisible,
            let step = state.step, step == .password || !userName.isEmpty
        {
            if disabledButtonReads > 0 {
                // The page has what was filled in, and enables its button a moment later.
                isFilled = true
            } else {
                state.submitted = step
                onSubmit?()
            }
        } else if case .own(_, _, _, let origin) = script, origin == state.origin, state.isVisible {
            state.ranScript = true
            onSubmit?()
        } else if case .submit(let origin) = script, origin == state.origin, isFilled {
            disabledButtonReads -= 1
            if disabledButtonReads <= 0 {
                isFilled = false
                state.submitted = state.step
                onSubmit?()
            }
        }
        state.awaitsSubmit = isFilled
        return state
    }

    func tap(at point: CGPoint) async throws {
        taps.append(point)
        onTap?()
    }
}

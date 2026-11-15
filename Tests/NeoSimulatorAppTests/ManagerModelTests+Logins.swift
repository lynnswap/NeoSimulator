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

    private var premium: SavedLogin {
        SavedLogin(
            applicationIdentifier: "com.example.app", label: "Premium", userName: "premium@example.com",
            origins: [WebOrigin("https://login.example.com")!])
    }

    /// A sign-in that looks often and does not wait long, for a device that answers at once.
    private func signIn(on device: SignInFixture) -> WebAuthenticationSignIn {
        var pace = WebAuthenticationSignIn.Pace()
        pace.appearance = .milliseconds(100)
        pace.completion = .milliseconds(100)
        pace.interval = .milliseconds(5)
        pace.tapAgain = .milliseconds(20)
        return WebAuthenticationSignIn(device: device, login: premium, password: "s3cret", pace: pace)
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
                    device.page = SignInPageState(origin: "https://login.example.com", hasPassword: true, document: "1")
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
                $0.page = SignInPageState(origin: "https://other.example", hasPassword: true)
            } == .unrecognizedPage(origin: "https://other.example"))
        // A sheet that closed leaves its page listed.
        #expect(
            await refused {
                $0.front = SignInFixture.application("com.example.app")
                $0.page = SignInPageState(origin: "https://login.example.com", isVisible: false, hasPassword: true)
            } == .noSheet)
    }

    @Test func aSignInThatDoesNotCloseTheSheetSaysWhyAndLeavesNoPassword() async throws {
        func outcome(after submit: @escaping (SignInFixture) -> Void) async -> WebAuthenticationSignIn.Failure? {
            let device = SignInFixture()
            device.front = SignInFixture.application("com.example.app")
            device.page = SignInPageState(origin: "https://login.example.com", hasPassword: true, document: "1")
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
        waiting.page = SignInPageState(origin: "https://login.example.com", hasPassword: true, document: "1")
        let (submissions, submitted) = AsyncStream.makeStream(of: Void.self)
        waiting.onSubmit = { submitted.yield() }
        let abandoned = Task { try await signIn(on: waiting).run() }
        for await _ in submissions { break }
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(waiting.scripts.last == .clear(origin: "https://login.example.com"))

        // The sheet went on to a page that is not the login's, such as one that asks for a code.
        #expect(
            await outcome { $0.page = SignInPageState(origin: "https://codes.example", hasPassword: false) }
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

    func pages() async throws -> [InspectablePage] { page == nil ? [] : [Self.sheet] }

    func run(_ script: SignInScript, in page: InspectablePage) async throws -> SignInPageState {
        // As the Web Inspector does, a cancelled task runs no script.
        try Task.checkCancellation()
        scripts.append(script)
        var state = try #require(self.page)
        if case .signIn(_, _, let origin) = script, origin == state.origin, state.isVisible, state.hasPassword {
            state.submitted = true
            onSubmit?()
        }
        return state
    }

    func tap(at point: CGPoint) async throws {
        taps.append(point)
        onTap?()
    }
}

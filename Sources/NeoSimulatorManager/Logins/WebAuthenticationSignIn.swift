import CoreGraphics
import Foundation
import NeoSimulatorDeviceIO

/// What a sign-in reads from a device and does to it.
@MainActor
package protocol SignInDevice: AnyObject {
    /// The frontmost application with its accessibility elements, or nil while the device names none.
    func frontmostApplication() async throws -> SimulatorAccessibilityElement?
    /// The web pages that the device's apps show.
    func pages() async throws -> [InspectablePage]
    func run(_ script: SignInScript, in page: InspectablePage) async throws -> SignInPageState
    /// Taps the screen at `point`, in unit coordinates from its top-left corner.
    func tap(at point: CGPoint) async throws
}

/// What a sign-in page shows, as a script of the sign-in reads it in the page.
package struct SignInPageState: Decodable, Equatable, Sendable {
    /// The page's origin as it serializes it, such as `https://login.example.com`.
    package var origin: String
    /// Whether the page is on the screen. The page of a sheet that has closed, or has yet to come up, stays listed
    /// and is hidden.
    package var isVisible: Bool
    /// Whether the page shows a field that takes a password to sign in with.
    package var hasPassword: Bool
    /// Whether `SignInScript.signIn` filled the page's form and submitted it.
    package var submitted: Bool
    /// Names the document, so that a page that loaded again is told from the one that was submitted.
    package var document: String

    package init(
        origin: String, isVisible: Bool = true, hasPassword: Bool, submitted: Bool = false, document: String = ""
    ) {
        self.origin = origin
        self.isVisible = isVisible
        self.hasPassword = hasPassword
        self.submitted = submitted
        self.document = document
    }
}

/// A script that a sign-in runs in a page. Each finds the page's sign-in fields and answers with the page's state.
///
/// The fields are found as a password manager finds them, from what the HTML standard has a form say about its
/// fields. The password field is the one with `autocomplete="current-password"`, or else the first field of the type
/// `password` that is not for a new password. The user name field is the one with `autocomplete="username"`, or else
/// a field before the password field: one for an email address, one whose name says that it is for a user name, or
/// the nearest.
///
/// A script that changes the page names the origin that the sign-in found the page at, and changes nothing if the
/// page is at another origin, or off the screen, by the time it runs. The check and the change are one run of script,
/// so the page cannot move between them.
package enum SignInScript: Equatable, Sendable {
    case state
    /// Sets the user name and the password, and submits the form that holds the password field.
    case signIn(userName: String, password: String, origin: String)
    /// Empties the fields that `signIn` set.
    case clear(origin: String)

    package var expression: String {
        let action: String
        switch self {
        case .state: action = ""
        case .signIn(let userName, let password, let origin):
            action = """
                if (location.origin === \(Self.literal(origin)) && isVisible && password && password.form) {
                  if (userName && \(Self.literal(userName)) !== '') set(userName, \(Self.literal(userName)));
                  set(password, \(Self.literal(password)));
                  const submit = Array.from(password.form.elements).find((e) => e.type === 'submit' && !e.disabled);
                  password.form.requestSubmit(submit);
                  submitted = true;
                }
                """
        case .clear(let origin):
            action = """
                if (location.origin === \(Self.literal(origin))) {
                  if (password) set(password, '');
                  if (userName) set(userName, '');
                }
                """
        }
        return """
            (() => {
              const takesInput = (e) => {
                const frame = e.getBoundingClientRect(), style = getComputedStyle(e);
                return frame.width > 0 && frame.height > 0 && style.visibility !== 'hidden' && !e.disabled && !e.readOnly;
              };
              const tokens = (e) => (e.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
              const inputs = Array.from(document.querySelectorAll('input')).filter(takesInput);
              const passwords = inputs.filter((e) => e.type === 'password' && !tokens(e).includes('new-password'));
              const password = passwords.find((e) => tokens(e).includes('current-password')) || passwords[0] || null;
              const texts = password
                ? inputs.filter((e) => ['text', 'email', 'tel'].includes(e.type) && e.form === password.form)
                : [];
              const before = texts.filter((e) => e.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING);
              const named = (e) => /user|login|email|account/i.test(e.name + ' ' + e.id);
              const userName = texts.find((e) => tokens(e).includes('username'))
                || before.find((e) => e.type === 'email' || tokens(e).includes('email'))
                || before.filter(named).pop() || before[before.length - 1] || null;
              const set = (e, value) => {
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, value);
                e.dispatchEvent(new Event('input', { bubbles: true }));
                e.dispatchEvent(new Event('change', { bubbles: true }));
              };
              const isVisible = document.visibilityState === 'visible';
              let submitted = false;
              \(action)
              return {
                origin: location.origin, isVisible, hasPassword: !!password, submitted,
                document: String(performance.timeOrigin),
              };
            })()
            """
    }

    /// A JavaScript string literal of `text`.
    private static func literal(_ text: String) -> String {
        // JSON's string is JavaScript's, and a string always encodes.
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}

/// Signs in to the web authentication session that an app shows, with a login that a person saved for the app.
///
/// It fills the login only into the sheet of the app that the login names, and only while the sheet's page is at one
/// of the login's origins. A sign-in that does not end with the sheet closed leaves no password in the page.
@MainActor
package struct WebAuthenticationSignIn {
    package enum Failure: Error, LocalizedError, Equatable {
        /// Another app than the login's is in front. Nil for the Home Screen and other system screens.
        case otherApplication(String?)
        /// The app showed no web authentication sheet in time.
        case noSheet
        /// The sheet's page is not at one of the login's origins, or shows no form that takes a password to sign in.
        case unrecognizedPage(origin: String?)
        /// The page asked for the password again.
        case rejected
        /// The sheet stayed open on a page that the sign-in could not read.
        case timedOut

        package var errorDescription: String? {
            switch self {
            case .otherApplication(let identifier?): "The login’s app is not in front. \(identifier) is."
            case .otherApplication(nil): "The login’s app is not in front."
            case .noSheet: "The app showed no web sign-in sheet. Start the sign-in in the app, then choose the login."
            case .unrecognizedPage(let origin?):
                "The page at \(origin) is not a sign-in page of the login: it is not at one of the login’s origins, "
                    + "or it shows no form with a password field."
            case .unrecognizedPage(nil): "The web sign-in sheet shows no page that the login can sign in to."
            case .rejected: "The page asked for the password again. It may have rejected the login."
            case .timedOut: "The sign-in did not finish in time."
            }
        }
    }

    /// How long each part of a sign-in waits, and how often it looks.
    package struct Pace: Sendable {
        /// For the sheet's sign-in page to show, from the start.
        package var appearance: Duration = .seconds(20)
        /// For the sheet to close after the form is submitted.
        package var completion: Duration = .seconds(20)
        package var interval: Duration = .milliseconds(250)
        /// Between two taps on the same alert. An alert that is still coming up ignores a tap.
        package var tapAgain: Duration = .seconds(1)

        package init() {}
    }

    private static let springBoard = "com.apple.springboard"
    /// The process that shows a web authentication session's page.
    private static let sheetService = "com.apple.SafariViewService"

    private let device: any SignInDevice
    private let login: SavedLogin
    private let password: String
    private let pace: Pace

    package init(device: any SignInDevice, login: SavedLogin, password: String, pace: Pace = Pace()) {
        self.device = device
        self.login = login
        self.password = password
        self.pace = pace
    }

    package func run() async throws {
        let (page, origin) = try await signInPage()
        let filled = try await device.run(.signIn(userName: login.userName, password: password, origin: origin), in: page)
        // The page moved, or lost its form, between the two scripts. Nothing was filled.
        guard filled.submitted else { throw Failure.unrecognizedPage(origin: filled.origin) }
        do {
            try await completion(of: page, submitting: filled.document)
        } catch {
            // What the sign-in put into the page does not stay there. A page that has moved on has dropped it already.
            _ = try? await device.run(.clear(origin: origin), in: page)
            throw error
        }
    }

    /// Waits for the sheet's sign-in page: accepts the system's consent alert on the way, and returns the page once it
    /// is at one of the login's origins and shows a password field.
    private func signInPage() async throws -> (InspectablePage, origin: String) {
        let deadline = ContinuousClock.now + pace.appearance
        var acceptedConsent: ContinuousClock.Instant?
        var lastOrigin: String?
        var sawSheet = false
        while true {
            if let application = try await device.frontmostApplication() {
                if application.bundleIdentifier == login.applicationIdentifier {
                    for page in try await device.pages() where page.bundleIdentifier == Self.sheetService {
                        let state = try await device.run(.state, in: page)
                        guard state.isVisible else { continue }
                        sawSheet = true
                        lastOrigin = state.origin
                        if isAllowed(state.origin), state.hasPassword { return (page, state.origin) }
                    }
                } else if application.bundleIdentifier != Self.springBoard {
                    throw Failure.otherApplication(application.bundleIdentifier)
                } else if let button = Self.consentButton(in: application, hosts: Set(login.origins.map(\.host))),
                    application.frame.width > 0, application.frame.height > 0
                {
                    // The alert was read just now, so the tap lands on it. One that is still coming up ignores the tap,
                    // and is tapped again if it is still there after a pause.
                    if acceptedConsent.map({ ContinuousClock.now - $0 >= pace.tapAgain }) ?? true {
                        try await device.tap(
                            at: CGPoint(
                                x: button.frame.midX / application.frame.width,
                                y: button.frame.midY / application.frame.height))
                        acceptedConsent = .now
                    }
                } else if acceptedConsent == nil {
                    throw Failure.otherApplication(nil)
                }
                // After the alert is answered, the system stays in front until the sheet is up.
            }
            guard ContinuousClock.now < deadline else {
                throw sawSheet ? Failure.unrecognizedPage(origin: lastOrigin) : Failure.noSheet
            }
            try await Task.sleep(for: pace.interval)
        }
    }

    private func isAllowed(_ origin: String) -> Bool {
        WebOrigin(origin).map(login.origins.contains) ?? false
    }

    /// The button that continues in the system's alert that asks whether an app may sign in with a site, if
    /// `springBoard` shows that alert for one of `hosts`. The alert's text is in the device's language. It quotes the
    /// site's host, and has two buttons, of which the trailing one continues.
    static func consentButton(
        in springBoard: SimulatorAccessibilityElement, hosts: Set<String>
    ) -> SimulatorAccessibilityElement? {
        var elements: [SimulatorAccessibilityElement] = []
        func collect(_ element: SimulatorAccessibilityElement) {
            elements.append(element)
            element.children.forEach(collect)
        }
        collect(springBoard)
        let buttons = elements.filter { $0.role == .button && !$0.frame.isEmpty }.sorted { $0.frame.minX < $1.frame.minX }
        let labels = elements.filter { $0.role == .staticText }.compactMap(\.label)
        guard buttons.count == 2, let message = labels.first(where: { label in hosts.contains { names($0, in: label) } })
        else { return nil }
        return isRightToLeft(message) ? buttons.first : buttons.last
    }

    /// Whether `text` has `host` as a whole host name, not as a part of a longer one.
    private static func names(_ host: String, in text: String) -> Bool {
        func continuesHost(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-")
        }
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: host, options: .caseInsensitive, range: search) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !continuesHost(before), !continuesHost(after) { return true }
            search = found.upperBound..<text.endIndex
        }
        return false
    }

    /// Whether `text` is in a script that is written from right to left, which is also how such a device lays out an
    /// alert's buttons.
    private static func isRightToLeft(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFDFF).contains($0.value)
                || (0xFE70...0xFEFF).contains($0.value)
        }
    }

    /// Waits for the sheet to close after the form is submitted from the document that `document` names.
    private func completion(of page: InspectablePage, submitting document: String) async throws {
        let deadline = ContinuousClock.now + pace.completion
        var last: SignInPageState?
        while true {
            let pages = try await device.pages()
            let isListed = pages.contains { $0.application == page.application && $0.identifier == page.identifier }
            // A page that is loading or closing may not answer.
            let state = isListed ? try? await device.run(.state, in: page) : nil
            if !isListed || state?.isVisible == false {
                // The sheet closed. Its page is also off the screen while another app is in front.
                let application = try await device.frontmostApplication()
                guard application?.bundleIdentifier == login.applicationIdentifier else {
                    throw Failure.otherApplication(application?.bundleIdentifier)
                }
                return
            }
            last = state ?? last
            // The sign-in page that loads again asks for the password again.
            if let state, isAllowed(state.origin), state.hasPassword, state.document != document { throw Failure.rejected }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pace.interval)
        }
        // A page that shows its answer without loading again still shows the password field.
        guard let last else { throw Failure.timedOut }
        throw isAllowed(last.origin) && last.hasPassword ? Failure.rejected : Failure.unrecognizedPage(origin: last.origin)
    }
}

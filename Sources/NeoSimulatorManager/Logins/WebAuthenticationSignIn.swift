import CoreGraphics
import Foundation
import NeoSimulatorDeviceIO

/// What a sign-in reads from a device and does to it.
@MainActor
package protocol SignInDevice: AnyObject {
    /// The frontmost application with its accessibility elements, or nil while the device names none.
    func frontmostApplication() async throws -> SimulatorAccessibilityElement?
    /// The accessibility element at a point of the screen, in points from its top-left corner.
    func element(at point: CGPoint) async throws -> SimulatorAccessibilityElement?
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
    /// Sets the user name and the password, and submits the form that holds the password field. It fills nothing in a
    /// form without a submit control: submitting such a form would run its default action, which the page does not use,
    /// and which can put the fields into a URL.
    case signIn(userName: String, password: String, origin: String)
    /// Empties the fields that `signIn` set in the page's document, which `signIn` noted there.
    case clear(origin: String)

    package var expression: String {
        let action: String
        switch self {
        case .state: action = ""
        case .signIn(let userName, let password, let origin):
            action = """
                // A control named `elements` or `requestSubmit` hides the form's own member of that name.
                const form = HTMLFormElement.prototype;
                const controls = password && password.form
                  ? Array.from(Object.getOwnPropertyDescriptor(form, 'elements').get.call(password.form)) : [];
                const submits = controls.filter((e) => e.type === 'submit' && !e.disabled);
                if (location.origin === \(Self.literal(origin)) && isVisible && submits.length > 0) {
                  // The fields are noted before they are filled, so that they can be emptied whatever follows.
                  window[filled] = userName && \(Self.literal(userName)) !== '' ? [userName, password] : [password];
                  if (window[filled].length > 1) set(userName, \(Self.literal(userName)));
                  set(password, \(Self.literal(password)));
                  // The form's button is the one a person would press after the password: the next that shows. A
                  // click runs what the page does for its button, and then submits the form as a person's click does.
                  const shown = submits.filter(takesInput);
                  const follows = (e) => password.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING;
                  const press = shown.find(follows) || shown[0];
                  // A form whose only submit control is hidden is submitted with Return, which names that control.
                  if (press) HTMLElement.prototype.click.call(press); else form.requestSubmit.call(password.form, submits[0]);
                  submitted = true;
                }
                """
        case .clear(let origin):
            action = """
                if (location.origin === \(Self.literal(origin))) {
                  // A page that is submitting can have disabled or hidden the fields, which no longer take input.
                  for (const field of window[filled] || []) set(field, '');
                  delete window[filled];
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
              const filled = Symbol.for('dev.lynnswap.NeoSimulator.filled');
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
        /// The sheet's page is not at one of the login's origins, or has no form with a password field and a control
        /// that submits it.
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
                    + "or it has no form with a password field and a button that submits it."
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
        do {
            let filled = try await device.run(
                .signIn(userName: login.userName, password: password, origin: origin), in: page)
            // The page moved, or lost its form, between the two scripts. Nothing was filled.
            guard filled.submitted else { throw Failure.unrecognizedPage(origin: filled.origin) }
            try await completion(of: page, submitting: filled.document)
        } catch {
            // What the sign-in put into the page does not stay there, also when its script failed part way or its
            // answer was lost. A page that has moved on has dropped it already. The clearing has a task of its own:
            // a sign-in that was cancelled, as by a tool that went away, runs no more script in its own.
            await Task { [device] in _ = try? await device.run(.clear(origin: origin), in: page) }.value
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
        var unreadable: (any Error)?
        while true {
            if let application = try await device.frontmostApplication() {
                if application.bundleIdentifier == login.applicationIdentifier {
                    for page in try await device.pages() where page.bundleIdentifier == Self.sheetService {
                        // The pages of sheets that closed stay listed, and one of them that cannot be read does not
                        // keep the sign-in from the sheet that is up.
                        let state: SignInPageState
                        do {
                            state = try await device.run(.state, in: page)
                        } catch let error where !(error is CancellationError) {
                            unreadable = error
                            continue
                        }
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
                if sawSheet { throw Failure.unrecognizedPage(origin: lastOrigin) }
                // A page that could not be read may have been the sheet's, such as one that another client inspects.
                throw unreadable ?? Failure.noSheet
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

    /// Where to tap to decline, in the unit coordinates of a tap, if the sheet offers to save the password.
    ///
    /// The offer is in the device's language, and nothing in its elements names it. It is told by its choices: two or
    /// three buttons of one size, each at least a quarter of the screen wide, that the sheet's own process puts over
    /// the page. Measured on iOS 26.5 and 27.2, three choices are stacked with the one that declines lowest, and two
    /// are side by side with the one that declines leading. Declining saves nothing and decides nothing for later.
    private func declineOfSavingPassword(in page: InspectablePage) async throws -> CGPoint? {
        // The service names the sheet's process by its process identifier, as in `PID:123`. The page's own elements
        // belong to another process, which renders it.
        guard let process = Int32(page.application.drop { !$0.isNumber }),
            let application = try await device.frontmostApplication(),
            application.bundleIdentifier == login.applicationIdentifier
        else { return nil }
        let screen = application.frame.size
        var buttons: [CGRect] = []
        var readsRightToLeft = false
        for x in [0.25, 0.5, 0.75] {
            for y in stride(from: 10.0, to: screen.height, by: 20) {
                guard let element = try await device.element(at: CGPoint(x: screen.width * x, y: y)),
                    element.processIdentifier == process
                else { continue }
                if element.role == .button, element.frame.width >= screen.width / 4, !buttons.contains(element.frame) {
                    buttons.append(element.frame)
                }
                // The offer's text and its buttons' titles are in the device's language.
                if let label = element.label, Self.isRightToLeft(label) { readsRightToLeft = true }
            }
        }
        let choices = buttons.filter { button in buttons.count { $0.size == button.size } > 1 }
        guard choices.count > 1, choices.allSatisfy({ $0.size == choices[0].size }) else { return nil }
        let isStacked = Set(choices.map(\.minY)).count > 1
        let decline = choices.max { first, second in
            if isStacked { return first.minY < second.minY }
            // The leading choice is the leftmost, or the rightmost where the device reads from right to left.
            return readsRightToLeft ? first.minX < second.minX : first.minX > second.minX
        }
        return decline.map { CGPoint(x: $0.midX / screen.width, y: $0.midY / screen.height) }
    }

    /// Waits for the sheet to close after the form is submitted from the document that `document` names.
    private func completion(of page: InspectablePage, submitting document: String) async throws {
        let deadline = ContinuousClock.now + pace.completion
        var last: SignInPageState?
        var declinedSaving: ContinuousClock.Instant?
        while true {
            // The sheet offers to save the password that its form submitted, and stays open until it is answered. An
            // offer that is still coming up ignores a tap, and is tapped again if it is still there after a pause.
            if declinedSaving.map({ ContinuousClock.now - $0 >= pace.tapAgain }) ?? true,
                let decline = try await declineOfSavingPassword(in: page)
            {
                try await device.tap(at: decline)
                declinedSaving = .now
            }
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

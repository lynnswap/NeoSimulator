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
    /// The application of a process with its accessibility elements, among them those that an alert or a sheet
    /// covers. It has no elements while it is not on the screen.
    func application(ofProcess processIdentifier: Int32) async throws -> SimulatorAccessibilityElement?
    /// Performs an action on one element of a process's application: the one whose index `choose` answers with, among
    /// the application's elements as they are then, in the order that they are read in and each without its children.
    func perform(
        _ action: SimulatorAccessibilityAction, inProcess processIdentifier: Int32,
        on choose: @escaping @Sendable ([SimulatorAccessibilityElement]) -> Int?
    ) async throws
}

/// What a sign-in page shows, as a script of the sign-in reads it in the page.
package struct SignInPageState: Decodable, Equatable, Sendable {
    /// The page's origin as it serializes it, such as `https://login.example.com`.
    package var origin: String
    /// Whether the page is on the screen. The page of a sheet that has closed, or has yet to come up, stays listed
    /// and is hidden.
    package var isVisible: Bool
    /// What the page asks for next in a form that the sign-in can submit, or nil for a page that asks for nothing that
    /// the sign-in recognizes.
    package var step: Step?
    /// The step that a script of the sign-in submitted, if it did.
    package var submitted: Step?
    /// Whether the document holds what `SignInScript.signIn` filled in and has yet to submit. A form's button can stay
    /// disabled until the page has looked at what was filled in.
    package var awaitsSubmit: Bool
    /// Names the document, so that a page that loaded again is told from the one that was submitted.
    package var document: String
    /// The page's path, without what follows it in its address.
    package var path: String
    /// Whether the login's own script ran in the page.
    package var ranScript: Bool
    /// Whether the page has finished loading, so that a script finds the elements that the page starts with.
    package var isLoaded: Bool

    /// A step of a sign-in, which a page asks for in a form. The steps come in this order, and a page that asks for a
    /// step that does not come later asks again.
    package enum Step: String, Decodable, Sendable, Comparable {
        /// The user name alone. The page asks for the password after it, on this page or the next.
        case userName
        /// The password, with the user name if the form also has a field for it.
        case password

        package static func < (first: Step, second: Step) -> Bool {
            first == .userName && second == .password
        }
    }

    package init(
        origin: String, isVisible: Bool = true, step: Step?, submitted: Step? = nil, awaitsSubmit: Bool = false,
        document: String = "", path: String = "/", ranScript: Bool = false, isLoaded: Bool = true
    ) {
        self.origin = origin
        self.isVisible = isVisible
        self.step = step
        self.submitted = submitted
        self.awaitsSubmit = awaitsSubmit
        self.document = document
        self.path = path
        self.ranScript = ranScript
        self.isLoaded = isLoaded
    }
}

/// A script that a sign-in runs in a page. Each finds the page's sign-in fields and answers with the page's state.
///
/// The fields are found as a password manager finds them, from what the HTML standard has a form say about its
/// fields. The password field is the one with `autocomplete="current-password"`, or else the first field of the type
/// `password` that is not for a new password. The user name field is the one with `autocomplete="username"`, or else
/// a field before the password field: one for an email address, one whose name says that it is for a user name, or
/// the nearest. On a page that shows no password field, the user name field is one that says so itself, with
/// `autocomplete="username"`, as an email field, or by its name.
///
/// A script that changes the page names the origin that the sign-in found the page at, and changes nothing if the
/// page is at another origin, or off the screen, by the time it runs. The check and the change are one run of script,
/// so the page cannot move between them.
package enum SignInScript: Equatable, Sendable {
    case state
    /// Fills in the step that the page asks for and submits its form: the password, with the user name where the form
    /// has a field for it, or the user name alone. It fills nothing in a form without a submit control: submitting such
    /// a form would run its default action, which the page does not use, and which can put the fields into a URL.
    case signIn(userName: String, password: String, origin: String)
    /// Submits the form that `signIn` filled in, once its button is enabled.
    case submit(origin: String)
    /// Runs a login's own script, which fills the page and submits it. The script is the body of a function that
    /// gets `login`, with the login's `userName` and `password`, and `fill(element, value)`, which sets a field's value
    /// as typing does and notes the field so that it can be emptied.
    case own(script: String, userName: String, password: String, origin: String)
    /// Empties the fields that `signIn` set in the page's document, which `signIn` noted there.
    case clear(origin: String)

    package var expression: String {
        let action: String
        switch self {
        case .state: action = ""
        case .signIn(let userName, let password, let origin):
            action = """
                if (location.origin === \(Self.literal(origin)) && isVisible && step
                    && (step === 'password' || \(Self.literal(userName)) !== '')) {
                  // The fields are noted before they are filled, so that they can be emptied whatever follows.
                  window[filled] = [];
                  if (userName && \(Self.literal(userName)) !== '') {
                    window[filled].push(userName);
                    set(userName, \(Self.literal(userName)));
                  }
                  if (step === 'password') {
                    window[filled].push(password);
                    set(password, \(Self.literal(password)));
                  }
                  if (press(asked)) submitted = step;
                }
                """
        case .submit(let origin):
            action = """
                // The form that was filled in is submitted, by the field that was noted last: a page can have put
                // another form in its place, and can have disabled the field while it looks at it.
                const noted = (window[filled] || []).filter((e) => e.isConnected);
                const last = noted[noted.length - 1];
                if (location.origin === \(Self.literal(origin)) && isVisible && last && press(last)) {
                  submitted = last.type === 'password' ? 'password' : 'userName';
                }
                """
        case .own(let script, let userName, let password, let origin):
            action = """
                if (location.origin === \(Self.literal(origin)) && isVisible && isLoaded) {
                  window[filled] = window[filled] || [];
                  const login = Object.freeze({ userName: \(Self.literal(userName)), password: \(Self.literal(password)) });
                  const fill = (element, value) => {
                    window[filled].push(element);
                    set(element, value);
                  };
                  // A page's content security policy that refuses `unsafe-eval` does not apply to what the Web
                  // Inspector evaluates, so the script is compiled here on such a page too.
                  new Function('login', 'fill', \(Self.literal(script)))(login, fill);
                  ranScript = true;
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
              // The controls that submit a field's form. A control named `elements` or `requestSubmit` hides the form's
              // own member of that name.
              const form = HTMLFormElement.prototype;
              const controlsOf = (e) => e && e.form
                ? Array.from(Object.getOwnPropertyDescriptor(form, 'elements').get.call(e.form)) : [];
              const submitsOf = (e) => controlsOf(e).filter((control) => control.type === 'submit');
              // A field counts where its form can be submitted.
              const fields = inputs.filter((e) => submitsOf(e).length > 0);
              const passwords = fields.filter((e) => e.type === 'password' && !tokens(e).includes('new-password'));
              const password = passwords.find((e) => tokens(e).includes('current-password')) || passwords[0] || null;
              const texts = fields.filter((e) => ['text', 'email', 'tel'].includes(e.type));
              const named = (e) => /user|login|email|account/i.test(e.name + ' ' + e.id);
              const isEmail = (e) => e.type === 'email' || tokens(e).includes('email');
              // Beside a password field, the field before it is the user name's. Alone, a field has to say so itself,
              // and the first that does is taken: a page's other forms come after the one that signs in. A form that
              // asks for a new password registers an account or changes one.
              const beside = password ? texts.filter((e) => e.form === password.form) : [];
              const before = beside.filter((e) => e.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING);
              const asksNewPassword = (e) => controlsOf(e).some((control) => tokens(control).includes('new-password'));
              const alone = texts.filter((e) => !asksNewPassword(e));
              const userName = password
                ? beside.find((e) => tokens(e).includes('username')) || before.find(isEmail)
                  || before.filter(named).pop() || before[before.length - 1] || null
                : alone.find((e) => tokens(e).includes('username') || isEmail(e) || named(e)) || null;
              // The field that the page asks for.
              const asked = password || userName;
              const step = !asked ? null : password ? 'password' : 'userName';
              // Presses the button of a field's form: the one a person would press after the field, which is the next
              // that shows. A click runs what the page does for its button, and then submits the form as a person's
              // click does. A form whose only submit control is hidden is submitted with Return, which names that
              // control. A button that the page keeps disabled until it has looked at the fields is not pressed yet.
              const press = (field) => {
                const enabled = submitsOf(field).filter((e) => !e.disabled);
                if (enabled.length === 0) return false;
                const shown = enabled.filter(takesInput);
                const follows = (e) => field.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING;
                const button = shown.find(follows) || shown[0];
                if (button) HTMLElement.prototype.click.call(button); else form.requestSubmit.call(field.form, enabled[0]);
                return true;
              };
              const set = (e, value) => {
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, value);
                e.dispatchEvent(new Event('input', { bubbles: true }));
                e.dispatchEvent(new Event('change', { bubbles: true }));
              };
              const isVisible = document.visibilityState === 'visible';
              const filled = Symbol.for('dev.lynnswap.NeoSimulator.filled');
              let submitted = null;
              let ranScript = false;
              // Scripts that a page defers, which can build its form, have run by then.
              const isLoaded = document.readyState === 'complete';
              \(action)
              return {
                origin: location.origin, isVisible, step, submitted, awaitsSubmit: !!window[filled] && !submitted,
                document: String(performance.timeOrigin), path: location.pathname, ranScript, isLoaded,
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

/// Signs in to what an app shows to sign in with, with a login that a person saved for the app: the sheet of a web
/// authentication session, or a form on the app's own screen, which a ``NativeFormSignIn`` fills.
///
/// It fills the login only into the sheet of the app that the login names, and only while the sheet's page is at one
/// of the login's origins. A sign-in that does not end with the sheet closed leaves no password in the page.
@MainActor
package struct WebAuthenticationSignIn {
    package enum Failure: Error, LocalizedError, Equatable {
        /// Another app than the login's is in front. Nil for the Home Screen and other system screens.
        case otherApplication(String?)
        /// The app showed no form of its own and no web authentication sheet in time.
        case noSheet
        /// The sheet's page is not at one of the login's origins, or has no form that asks for a step of the sign-in
        /// with a control that submits it.
        case unrecognizedPage(origin: String?)
        /// The page asked again for what the sign-in had filled in.
        case rejected
        /// The sheet stayed open on a page that the sign-in could not read.
        case timedOut

        package var errorDescription: String? {
            switch self {
            case .otherApplication(let identifier?): "The login’s app is not in front. \(identifier) is."
            case .otherApplication(nil): "The login’s app is not in front."
            case .noSheet:
                "The app showed no sign-in form and no web sign-in sheet. Open the app’s sign-in screen, then choose "
                    + "the login."
            case .unrecognizedPage(let origin?):
                "The page at \(origin) is not a sign-in page of the login: it is not at one of the login’s origins, "
                    + "or it has no form that asks for the user name or the password with a button that submits it."
            case .unrecognizedPage(nil): "The web sign-in sheet shows no page that the login can sign in to."
            case .rejected: "The page asked for the same again. It may have rejected the login."
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
        /// For a form's button to be enabled after its fields are filled in.
        package var button: Duration = .seconds(3)
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
        let page: InspectablePage
        var origin: String
        switch try await signInScreen() {
        case .form(let form): return try await form.run()
        case .page(let shown, let first): (page, origin) = (shown, first)
        }
        do {
            switch login.webSignIn {
            case .automatic: try await fillSteps(of: page, at: &origin)
            case .script: try await runOwnScript(in: page, at: &origin)
            }
        } catch {
            // What the sign-in put into the page does not stay there, also when a script failed part way or its
            // answer was lost. A page that has moved on has dropped it already. The clearing has a task of its own: a
            // sign-in that was cancelled, as by a tool that went away, runs no more script in its own.
            await Task { [device, origin] in _ = try? await device.run(.clear(origin: origin), in: page) }.value
            throw error
        }
    }

    /// Fills in what the page asks for, with the built-in filling, until the sheet closes. `origin` is the origin of
    /// the page that was filled last.
    private func fillSteps(of page: InspectablePage, at origin: inout String) async throws {
        // A page asks for the user name alone, or for the password. Each page that follows has to ask for a later
        // step, so a sign-in fills in two pages at most.
        while true {
            var filled = try await device.run(
                .signIn(userName: login.userName, password: password, origin: origin), in: page)
            // A page can keep its button disabled until it has looked at the fields.
            let enabled = ContinuousClock.now + pace.button
            while filled.submitted == nil, filled.awaitsSubmit, ContinuousClock.now < enabled {
                try await Task.sleep(for: pace.interval)
                filled = try await device.run(.submit(origin: origin), in: page)
            }
            // The page moved, or lost its form, between the scripts, it asks for a user name that the login does not
            // have, or its button stayed disabled. What was filled in is cleared.
            guard let submitted = filled.submitted else { throw Failure.unrecognizedPage(origin: filled.origin) }
            let next = try await originOfNextStep(after: submitted, from: filled.document, of: page)
            // The sheet closed.
            guard let next else { return }
            origin = next
        }
    }

    /// Runs the login's own script in the pages of the sign-in until the sheet closes. `origin` is the origin of the
    /// page that the script ran in last.
    ///
    /// The script runs once in each document at one of the login's origins. A page is told by its origin and path:
    /// one that loads again after the script ran in it asks again, which ends the sign-in as rejected, so that a
    /// login that a site refuses is not submitted over and over.
    private func runOwnScript(in page: InspectablePage, at origin: inout String) async throws {
        var deadline = ContinuousClock.now + pace.completion
        var addresses: Set<String> = []
        var document: String?
        var last: SignInPageState?
        var declinedSaving: ContinuousClock.Instant?
        while true {
            try await declineSavingPassword(in: page, tapped: &declinedSaving)
            guard case .open(let state) = try await sheet(showing: page) else { return }
            last = state ?? last
            // A document that is still being read in does not have the elements that a script looks for.
            if let state, isAllowed(state.origin), state.isLoaded, state.document != document {
                guard !addresses.contains(state.origin + state.path) else { throw Failure.rejected }
                origin = state.origin
                let ran = try await device.run(
                    .own(script: login.script, userName: login.userName, password: password, origin: state.origin),
                    in: page)
                // A page that moved to another origin between the two scripts did not run it, and is looked at again.
                // The page that it ran in is the one that answers, which can be a later one at the same origin.
                if ran.ranScript {
                    addresses.insert(ran.origin + ran.path)
                    document = ran.document
                    deadline = ContinuousClock.now + pace.completion
                }
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pace.interval)
        }
        guard let last, isAllowed(last.origin) else { throw Failure.unrecognizedPage(origin: last?.origin) }
        throw Failure.timedOut
    }

    /// What an app shows to sign in with.
    private enum Screen {
        /// The page of a web authentication session's sheet, with its origin.
        case page(InspectablePage, origin: String)
        /// A form on the app's own screen.
        case form(NativeFormSignIn)
    }

    /// Waits for what the login's app shows to sign in with, so that a caller can ask as soon as it has opened the
    /// app's sign-in screen. For a sheet, it accepts the system's consent alert on the way, and returns the page once
    /// it is at one of the login's origins and asks for a step of the sign-in.
    private func signInScreen() async throws -> Screen {
        let deadline = ContinuousClock.now + pace.appearance
        var acceptedConsent: ContinuousClock.Instant?
        var lastOrigin: String?
        var sawSheet = false
        var unreadable: (any Error)?
        var unrecognizedForm: NativeFormSignIn.Failure?
        // A tap that lands after the deadline gets one read of what it brought up; another such tap ends the wait.
        var readAfterDeadline = false
        while true {
            if let application = try await device.frontmostApplication() {
                if application.bundleIdentifier == login.applicationIdentifier {
                    // A screen that is still coming up can have its password field before its button.
                    do {
                        let form = try NativeFormSignIn(
                            device: device, login: login, password: password, in: application, pace: pace)
                        if let form { return .form(form) }
                        unrecognizedForm = nil
                    } catch let failure as NativeFormSignIn.Failure {
                        unrecognizedForm = failure
                    }
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
                        // The login's own script decides what a page asks for, once the page has been read in.
                        if isAllowed(state.origin), login.webSignIn == .script ? state.isLoaded : state.step != nil {
                            return .page(page, origin: state.origin)
                        }
                    }
                } else if application.bundleIdentifier != Self.springBoard {
                    throw Failure.otherApplication(application.bundleIdentifier)
                } else if let button = Self.consentButton(in: application, hosts: Set(login.origins.map(\.host))),
                    application.frame.width > 0, application.frame.height > 0
                {
                    // The alert was read just now, so the tap lands on it. One that is still coming up ignores the tap,
                    // and is tapped again if it is still there after a pause.
                    if acceptedConsent.map({ ContinuousClock.now - $0 >= pace.tapAgain }) ?? true {
                        let expired = ContinuousClock.now >= deadline
                        if expired, readAfterDeadline { break }
                        try await device.tap(
                            at: CGPoint(
                                x: button.frame.midX / application.frame.width,
                                y: button.frame.midY / application.frame.height))
                        acceptedConsent = .now
                        if expired { readAfterDeadline = true }
                        // The tap can bring the sheet up; read the screen again before the deadline decides that
                        // no sheet came.
                        continue
                    }
                } else if acceptedConsent == nil {
                    throw Failure.otherApplication(nil)
                }
                // After the alert is answered, the system stays in front until the sheet is up.
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pace.interval)
        }
        if let unrecognizedForm { throw unrecognizedForm }
        if sawSheet { throw Failure.unrecognizedPage(origin: lastOrigin) }
        // A page that could not be read may have been the sheet's, such as one that another client inspects.
        throw unreadable ?? Failure.noSheet
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

    /// What the sheet shows: its page's state, where the page answers, or nothing once it has closed.
    private enum Sheet {
        case closed
        /// A page that is loading or closing may not answer.
        case open(SignInPageState?)
    }

    private func sheet(showing page: InspectablePage) async throws -> Sheet {
        let pages = try await device.pages()
        let isListed = pages.contains { $0.application == page.application && $0.identifier == page.identifier }
        let state = isListed ? try? await device.run(.state, in: page) : nil
        guard !isListed || state?.isVisible == false else { return .open(state) }
        // The sheet closed. Its page is also off the screen while another app is in front.
        let application = try await device.frontmostApplication()
        guard application?.bundleIdentifier == login.applicationIdentifier else {
            throw Failure.otherApplication(application?.bundleIdentifier)
        }
        return .closed
    }

    /// Declines the sheet's offer to save the password, if it shows. The sheet offers that for a password that its form
    /// submitted, and stays open until the offer is answered. An offer that is still coming up ignores a tap, and is
    /// tapped again if it is still there after a pause.
    private func declineSavingPassword(in page: InspectablePage, tapped: inout ContinuousClock.Instant?) async throws {
        guard tapped.map({ ContinuousClock.now - $0 >= pace.tapAgain }) ?? true,
            let decline = try await declineOfSavingPassword(in: page)
        else { return }
        try await device.tap(at: decline)
        tapped = .now
    }

    /// Waits for what follows a step that was submitted from the document that `document` names. Returns nil once the
    /// sheet has closed, and the page's origin once the page asks for a later step at one of the login's origins. The
    /// page that asks for a later step can be another document, at another of the login's origins.
    private func originOfNextStep(
        after submitted: SignInPageState.Step, from document: String, of page: InspectablePage
    ) async throws -> String? {
        let deadline = ContinuousClock.now + pace.completion
        var last: SignInPageState?
        var declinedSaving: ContinuousClock.Instant?
        while true {
            if submitted == .password { try await declineSavingPassword(in: page, tapped: &declinedSaving) }
            guard case .open(let state) = try await sheet(showing: page) else { return nil }
            last = state ?? last
            if let state, isAllowed(state.origin), let step = state.step {
                if step > submitted { return state.origin }
                // The sign-in page that loads again asks again for what was filled in.
                if state.document != document { throw Failure.rejected }
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pace.interval)
        }
        // A page that shows its answer without loading again still asks for the same.
        guard let last else { throw Failure.timedOut }
        guard isAllowed(last.origin), last.step != nil else { throw Failure.unrecognizedPage(origin: last.origin) }
        throw Failure.rejected
    }
}

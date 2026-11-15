import CoreGraphics
import Foundation
import NeoSimulatorDeviceIO

/// Signs in to the form that an app shows on its own screen, with a login that a person saved for the app.
///
/// The form is found in the app's accessibility elements, and is filled and submitted through them: the fields get
/// their values whole, as an assistive technology sets them, and the button is pressed as one presses it. Nothing is
/// tapped or typed, so the keyboard and what is in front of the form play no part.
///
/// The login goes only to elements of the process that is the login's app, and the password only to a field that
/// hides what it holds. A sign-in that does not end with the form gone leaves neither in the form.
@MainActor
package struct NativeFormSignIn {
    /// The elements of a sign-in form, each without its children.
    package struct Form: Equatable, Sendable {
        /// The text field before the password's, if the screen has one.
        package var userName: SimulatorAccessibilityElement?
        package var password: SimulatorAccessibilityElement
        /// The button that submits the form.
        package var button: SimulatorAccessibilityElement
    }

    package enum Failure: Error, LocalizedError, Equatable {
        /// The screen has more than one password field.
        case severalPasswordFields
        /// The screen has no button to press: none after the password field, or not exactly one that the login
        /// names. `buttons` are the screen's buttons as a login names them, so that the login can be set right
        /// without another look at the screen.
        case noButton(named: String?, buttons: [String])
        /// A field did not hold what the sign-in set.
        case notFilled
        /// The app still showed the form when the wait ended.
        case rejected
        /// The app showed nothing that the sign-in could read when the wait ended.
        case timedOut

        package var errorDescription: String? {
            switch self {
            case .severalPasswordFields:
                "The app’s screen has more than one password field, as a form that registers an account has."
            case .noButton(let name?, let buttons):
                "The app’s screen does not have exactly one button that the login’s Sign-In Button, \(name), names. "
                    + Self.listing(buttons)
            case .noButton(nil, let buttons):
                "The app’s screen has no button after its password field. Set the login’s Sign-In Button. "
                    + Self.listing(buttons)
            case .notFilled: "The app’s sign-in form did not take the login."
            case .rejected: "The app still shows its sign-in form. It may have rejected the login."
            case .timedOut: "The sign-in did not finish in time."
            }
        }

        private static func listing(_ buttons: [String]) -> String {
            buttons.isEmpty ? "The screen has no buttons." : "The screen’s buttons: \(buttons.joined(separator: ", "))."
        }
    }

    private let device: any SignInDevice
    private let login: SavedLogin
    private let password: String
    private let pace: WebAuthenticationSignIn.Pace
    private let form: Form
    /// The process of the login's app, whose elements the sign-in reads and changes.
    private let processIdentifier: Int32

    /// A sign-in to the form that `application` shows, or nil if `application` is not the login's app or shows no
    /// password field, as while the app shows a web sign-in sheet. Throws a ``Failure`` for a screen with a password
    /// field that is not a form which the sign-in can fill.
    ///
    /// - Parameter application: The frontmost application with the elements that are on its screen now.
    package init?(
        device: any SignInDevice, login: SavedLogin, password: String, in application: SimulatorAccessibilityElement,
        pace: WebAuthenticationSignIn.Pace = WebAuthenticationSignIn.Pace()
    ) throws {
        guard application.bundleIdentifier == login.applicationIdentifier,
            let form = try Self.form(in: application, button: login.signInButton)
        else { return nil }
        self.device = device
        self.login = login
        self.password = password
        self.pace = pace
        self.form = form
        processIdentifier = application.processIdentifier
    }

    /// The sign-in form among an application's elements, or nil if they have no password field.
    ///
    /// The password field is the screen's one text field that hides what it holds. The user name field is the text
    /// field before it, in the order that the elements are read in. The button is the one that `name` names, or for
    /// no name the first after the password field. A name is a button's label, or `#` and its accessibility
    /// identifier, as in `#signIn`.
    static func form(in application: SimulatorAccessibilityElement, button name: String) throws -> Form? {
        var elements: [SimulatorAccessibilityElement] = []
        func collect(_ element: SimulatorAccessibilityElement) {
            var alone = element
            alone.children = []
            if !alone.frame.isEmpty { elements.append(alone) }
            element.children.forEach(collect)
        }
        collect(application)
        let passwords = elements.indices.filter { elements[$0].role == .textField && elements[$0].isSecureTextField }
        guard let password = passwords.first else { return nil }
        guard passwords.count == 1 else { throw Failure.severalPasswordFields }
        let buttons = elements.indices.filter { elements[$0].role == .button }
        let button: Int?
        if name.isEmpty {
            button = buttons.first { $0 > password }
        } else {
            let named = buttons.filter {
                name.hasPrefix("#") ? elements[$0].identifier == String(name.dropFirst()) : elements[$0].label == name
            }
            button = named.count == 1 ? named[0] : nil
        }
        guard let button else {
            // An identifier names a button whatever language its label is in.
            let names = buttons.compactMap { index in
                elements[index].identifier.map { "#" + $0 } ?? elements[index].label
            }
            throw Failure.noButton(named: name.isEmpty ? nil : name, buttons: names)
        }
        return Form(
            userName: elements[..<password].last { $0.role == .textField },
            password: elements[password], button: elements[button])
    }

    package func run() async throws {
        do {
            if let userName = form.userName, !login.userName.isEmpty {
                try await device.perform(.setValue(login.userName), on: userName)
            }
            try await device.perform(.setValue(password), on: form.password)
            try await checkFilled()
            try await device.perform(.press, on: form.button)
            try await waitForFormToGo()
        } catch {
            // What the sign-in put into the form does not stay there. The clearing has a task of its own: a sign-in
            // that was cancelled, as by a tool that went away, changes no more elements in its own.
            await Task { [device, form] in
                for field in [form.password, form.userName].compactMap(\.self) {
                    try? await device.perform(.setValue(""), on: field)
                }
            }.value
            throw error
        }
    }

    /// The app's element that `element` was read as, as it is now.
    private func current(_ element: SimulatorAccessibilityElement) async throws -> SimulatorAccessibilityElement? {
        func find(in parent: SimulatorAccessibilityElement) -> SimulatorAccessibilityElement? {
            if parent.role == element.role, parent.isSecureTextField == element.isSecureTextField,
                parent.identifier == element.identifier, parent.frame == element.frame
            {
                return parent
            }
            return parent.children.lazy.compactMap(find).first
        }
        return try await device.application(ofProcess: processIdentifier).flatMap(find)
    }

    /// An element that takes no value answers a request to set one as a field does, so the fields are read again. A
    /// field that hides what it holds reads as one bullet for each character.
    private func checkFilled() async throws {
        if let userName = form.userName, !login.userName.isEmpty {
            guard try await current(userName)?.value == login.userName else { throw Failure.notFilled }
        }
        guard let hidden = try await current(form.password)?.value, !hidden.isEmpty, hidden.allSatisfy({ $0 == "•" })
        else { throw Failure.notFilled }
    }

    /// Waits until the app's elements no longer have a password field. The app's own elements answer while an alert of
    /// the app or of the system covers the form, so an alert that says why the login was not taken does not look like
    /// a form that is gone.
    private func waitForFormToGo() async throws {
        let deadline = ContinuousClock.now + pace.completion
        var showsForm = false
        while true {
            // An app that is not on the screen answers without elements, and may still show the form.
            if let application = try await device.application(ofProcess: processIdentifier), !application.children.isEmpty {
                showsForm = Self.hasPasswordField(application)
                if !showsForm { return }
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pace.interval)
        }
        throw showsForm ? Failure.rejected : Failure.timedOut
    }

    private static func hasPasswordField(_ element: SimulatorAccessibilityElement) -> Bool {
        (element.role == .textField && element.isSecureTextField) || element.children.contains(where: hasPasswordField)
    }
}

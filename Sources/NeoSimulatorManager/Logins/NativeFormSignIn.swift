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
    /// Where the elements of a sign-in form are among an app's elements.
    package struct Form: Equatable, Sendable {
        /// The text field before the password's, if the screen has one.
        package var userName: Int?
        package var password: Int
        /// The button that submits the form.
        package var button: Int
    }

    package enum Failure: Error, LocalizedError, Equatable {
        /// The screen has more than one password field.
        case severalPasswordFields
        /// The screen has no button to press: none after the password field, or not exactly one that the login
        /// names. `buttons` are the screen's buttons as a login names them, so that the login can be set right
        /// without another look at the screen. They are read before anything is filled in: what an app shows
        /// afterwards can repeat the login.
        case noButton(named: String?, buttons: [String])
        /// A field did not hold what the sign-in set.
        case notFilled
        /// The form's button was gone or disabled for as long as the sign-in waited to press it.
        case buttonUnavailable
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
            case .buttonUnavailable:
                "The app’s sign-in button was gone or disabled after the login was filled in."
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
    /// Whether the sign-in fills in the user name: the form has a field for it, and the login has one.
    private let fillsUserName: Bool
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
            let form = try Self.form(among: Self.elements(of: application), button: login.signInButton)
        else { return nil }
        self.device = device
        self.login = login
        self.password = password
        self.pace = pace
        fillsUserName = form.userName != nil && !login.userName.isEmpty
        processIdentifier = application.processIdentifier
    }

    /// An element and those under it in the order that they are read in, each without its children.
    package nonisolated static func elements(
        of element: SimulatorAccessibilityElement
    ) -> [SimulatorAccessibilityElement] {
        var alone = element
        alone.children = []
        return [alone] + element.children.flatMap(elements)
    }

    /// The elements of an app's own process that its screen shows, by where they are among `elements`, of which the
    /// first is the application. A web view's page belongs to another process, and a login gets into a page only
    /// where the page's origin is one of the login's: measured on iOS 27.2, the elements of an app with a web view
    /// do not have the page's, and the element at a point of the page is one of the process that renders it.
    private nonisolated static func shown(among elements: [SimulatorAccessibilityElement]) -> [Int] {
        // An element without a frame is not one that the screen shows.
        elements.indices.filter {
            !elements[$0].frame.isEmpty && elements[$0].processIdentifier == elements[0].processIdentifier
        }
    }

    /// The app's text fields that hide what they hold.
    private nonisolated static func passwordFields(among elements: [SimulatorAccessibilityElement]) -> [Int] {
        shown(among: elements).filter { elements[$0].role == .textField && elements[$0].isSecureTextField }
    }

    /// The text field before a password field, in the order that the elements are read in.
    private nonisolated static func userNameField(
        before password: Int, among elements: [SimulatorAccessibilityElement]
    ) -> Int? {
        shown(among: elements).last { $0 < password && elements[$0].role == .textField }
    }

    /// The fields of the sign-in form among an app's elements, or nil if they have no password field.
    ///
    /// The password field is the screen's one text field that hides what it holds. The user name field is the text
    /// field before it.
    nonisolated static func fields(
        among elements: [SimulatorAccessibilityElement]
    ) throws -> (userName: Int?, password: Int)? {
        let passwords = passwordFields(among: elements)
        guard let password = passwords.first else { return nil }
        guard passwords.count == 1 else { throw Failure.severalPasswordFields }
        return (userNameField(before: password, among: elements), password)
    }

    /// The sign-in form among an app's elements, or nil if they have no password field.
    ///
    /// The button is the one that `name` names, or for no name the first after the password field. A name is a
    /// button's label, or `#` and its accessibility identifier, as in `#signIn`.
    package nonisolated static func form(
        among elements: [SimulatorAccessibilityElement], button name: String
    ) throws -> Form? {
        guard let (userName, password) = try fields(among: elements) else { return nil }
        let buttons = shown(among: elements).filter { elements[$0].role == .button }
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
        return Form(userName: userName, password: password, button: button)
    }

    package func run() async throws {
        do {
            if fillsUserName { try await perform(.setValue(login.userName), on: .userName) }
            try await perform(.setValue(password), on: .password)
            try await checkFilled()
            try await pressButton()
            try await waitForFormToGo()
        } catch {
            // What the sign-in put into the form does not stay there. The clearing has a task of its own: a sign-in
            // that was cancelled, as by a tool that went away, changes no more elements in its own.
            await Task { await clear() }.value
            throw error
        }
    }

    /// Empties what the sign-in filled in. The screen can have changed since, as to one that asks for the password
    /// twice, so each password field of the app is emptied, whatever it reads as, and the text field before them if
    /// the sign-in set it.
    private func clear() async {
        let processIdentifier = processIdentifier
        func empty(_ choose: @escaping @Sendable ([SimulatorAccessibilityElement]) -> Int?) async -> Bool {
            (try? await device.perform(.setValue(""), inProcess: processIdentifier, on: choose)) != nil
        }
        if fillsUserName {
            _ = await empty { elements in
                Self.passwordFields(among: elements).first.flatMap { Self.userNameField(before: $0, among: elements) }
            }
        }
        // A form has a password field, or two where it asks for the password again.
        for field in 0..<4 {
            let emptied = await empty { elements in
                let passwords = Self.passwordFields(among: elements)
                return passwords.indices.contains(field) ? passwords[field] : nil
            }
            if !emptied { break }
        }
    }

    /// Presses the form's button once the app has it enabled. An app can keep the button disabled, or take it away,
    /// until it has looked at the fields, and a disabled button answers a press and does nothing.
    private func pressButton() async throws {
        let deadline = ContinuousClock.now + pace.button
        while true {
            if let application = try await device.application(ofProcess: processIdentifier) {
                let elements = Self.elements(of: application)
                if let form = try? Self.form(among: elements, button: login.signInButton),
                    elements[form.button].isEnabled
                {
                    return try await perform(.press, on: .button)
                }
            }
            guard ContinuousClock.now < deadline else { throw Failure.buttonUnavailable }
            try await Task.sleep(for: pace.interval)
        }
    }

    private enum Part {
        case userName, password, button
    }

    /// Performs an action on a part of the form as the app has it when the action is asked for. Setting a field's
    /// value can bring up the keyboard, which moves the form, so a part is found again for each action. A field is
    /// found without the button: an app can take its button away while it looks at what was submitted, and the
    /// fields are still emptied then.
    private func perform(_ action: SimulatorAccessibilityAction, on part: Part) async throws {
        let name = login.signInButton
        try await device.perform(action, inProcess: processIdentifier) { elements in
            switch part {
            case .userName: (try? Self.fields(among: elements)).flatMap { $0 }?.userName
            case .password: (try? Self.fields(among: elements)).flatMap { $0 }?.password
            case .button:
                (try? Self.form(among: elements, button: name)).flatMap { $0 }
                    .flatMap { elements[$0.button].isEnabled ? $0.button : nil }
            }
        }
    }

    /// An element that takes no value answers a request to set one as a field does, so the fields are read again. A
    /// field that hides what it holds reads as one bullet for each UTF-16 unit of it, measured on iOS 27.2.
    private func checkFilled() async throws {
        guard let application = try await device.application(ofProcess: processIdentifier) else {
            throw Failure.notFilled
        }
        let elements = Self.elements(of: application)
        guard let fields = try Self.fields(among: elements),
            elements[fields.password].value == String(repeating: "•", count: password.utf16.count)
        else { throw Failure.notFilled }
        if fillsUserName {
            guard let userName = fields.userName, elements[userName].value == login.userName else {
                throw Failure.notFilled
            }
        }
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
                showsForm = !Self.passwordFields(among: Self.elements(of: application)).isEmpty
                if !showsForm { return }
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: pace.interval)
        }
        throw showsForm ? Failure.rejected : Failure.timedOut
    }
}

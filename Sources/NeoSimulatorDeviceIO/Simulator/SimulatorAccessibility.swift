import CoreGraphics
import Foundation

/// An element of a simulator's accessibility, as VoiceOver reads it.
package struct SimulatorAccessibilityElement: Equatable, Sendable {
    /// What an element is, by the accessibility translator's numbers.
    package enum Role: Int, Sendable {
        case application = 1
        case button, checkBox, genericElement, group, heading, image, link, radioButton, scrollArea, scrollBar
        case tabGroup, slider, staticText, textField, webArea, textArea, splitter, popUpButton, sheet, grid
    }

    /// Nil for a role that this build does not name.
    package var role: Role?
    /// Whether the element is a text field that hides what it holds. Its value is then one bullet for each character.
    package var isSecureTextField: Bool
    /// Whether the element takes input. A button that an app has disabled answers a press and does nothing.
    package var isEnabled: Bool
    package var label: String?
    package var value: String?
    package var identifier: String?
    /// In points of the display, from its top-left corner.
    package var frame: CGRect
    /// The guest process that the element belongs to.
    package var processIdentifier: Int32
    /// The bundle identifier of the app that the element belongs to, where its process reports one.
    package var bundleIdentifier: String?
    package var children: [SimulatorAccessibilityElement]

    package init(
        role: Role?, isSecureTextField: Bool = false, isEnabled: Bool = true, label: String? = nil,
        value: String? = nil, identifier: String? = nil, frame: CGRect, processIdentifier: Int32,
        bundleIdentifier: String? = nil, children: [SimulatorAccessibilityElement] = []
    ) {
        self.role = role
        self.isSecureTextField = isSecureTextField
        self.isEnabled = isEnabled
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.children = children
    }
}

/// A request for a device's accessibility that the guest answered with an error, such as for an app that does not
/// respond. The guest answers that after about three seconds.
package struct SimulatorAccessibilityFailure: LocalizedError, Equatable {
    /// The translator's error number.
    package let code: UInt64

    package var errorDescription: String? {
        "The device answered a request for its accessibility with error \(code). The app may not be responding."
    }
}

/// What an assistive technology does to an element.
package enum SimulatorAccessibilityAction: Equatable, Sendable {
    /// Presses the element, as a button.
    case press
    /// Sets the element's value, as a text field's. The app gets the value whole, without keys or a keyboard.
    case setValue(String)
}

/// Why an element did not get an action.
package enum SimulatorAccessibilityActionFailure: LocalizedError, Equatable {
    /// The app has no element for the action.
    case elementGone
    /// The element answered that it did not take the action.
    case refused

    package var errorDescription: String? {
        switch self {
        case .elementGone: "The app no longer shows the element."
        case .refused: "The element did not take the action."
        }
    }
}

/// Reads and changes elements through the accessibility translator's requests to one device.
///
/// A request that names no client is answered with the elements that VoiceOver reads: those accessible on the screen
/// now. A client that asks for the automation tree also gets the elements that an alert or a sheet covers.
struct SimulatorAccessibilityReader {
    /// A translation object's process and its number within that process, which together name one element.
    struct Identity: Hashable {
        let processIdentifier: Int32
        let objectID: UInt64
    }

    /// The translator's request types that the reader sends.
    enum Request: UInt64 {
        case application = 1
        case frontmostApplication = 4
        case attributes = 5
        case hitTest = 6
        case action = 7
        case setAttribute = 8
    }

    /// A request to the guest's translator.
    struct Message {
        var request: Request
        /// The translation object that the request is about, or nil for none.
        var element: AnyObject?
        var parameters: [String: Any] = [:]
        /// The translator's number of the attribute that the request sets, or 0.
        var attribute: UInt64 = 0
        /// The translator's number of the action that the request performs, or 0.
        var action: UInt64 = 0
    }

    /// The translator's attribute numbers that a read asks for.
    private enum Attribute: Int, CaseIterable {
        case bundleIdentifier = 6
        case children = 8
        case frame = 21
        case identifier = 25
        case isEnabled = 27
        case label = 33
        case role = 45
        case subrole = 51
        case value = 53
    }

    /// The translator's subrole number for a secure text field.
    private static let secureTextField = 5
    /// The translator's action number for a press.
    private static let press: UInt64 = 5
    /// The translator's error number for nothing accessible at a point, or an element that is gone.
    private static let noElement: UInt64 = 8

    /// What the guest answered: the translator's error number, 0 for none, and the response's result.
    struct Answer {
        var error: UInt64 = 0
        var result: Any?
    }

    /// Sends a request and waits for the guest's answer.
    let send: (Message) throws -> Answer
    /// Names a translation object, or nil for an object that is not one.
    let identity: (AnyObject) throws -> Identity?

    /// The main display's frontmost application with its elements, or nil if the guest names none.
    func frontmostApplication() throws -> SimulatorAccessibilityElement? {
        guard let root = try result(of: .frontmostApplication, nil, ["displayId": 0]) else { return nil }
        var ancestors: Set<Identity> = []
        return try read(root as AnyObject, descending: true, ancestors: &ancestors)
    }

    /// The element at `point` of the main display, in whichever process draws there, without its children.
    func element(at point: CGPoint) throws -> SimulatorAccessibilityElement? {
        let parameters: [String: Any] = ["point": NSValue(point: point), "displayId": 0]
        guard let found = try result(of: .hitTest, nil, parameters) else { return nil }
        var ancestors: Set<Identity> = []
        return try read(found as AnyObject, descending: false, ancestors: &ancestors)
    }

    /// The application of a guest process with its elements, or nil if the guest names none for the process. An
    /// application that is not on the screen answers without elements.
    func application(processIdentifier: Int32) throws -> SimulatorAccessibilityElement? {
        guard let root = try result(of: .application, nil, ["pid": processIdentifier]) else { return nil }
        var ancestors: Set<Identity> = []
        return try read(root as AnyObject, descending: true, ancestors: &ancestors)
    }

    /// Performs `action` on one element of a process's application: the one whose index `choose` answers with, among
    /// the application's elements in the order that they are read in, each without its children. The elements are
    /// read for the action, so the choice is made from what the application has now: setting a field's value can
    /// bring up the keyboard, which moves the elements that were read before. A press that the element refuses, and
    /// no choice, throw a ``SimulatorAccessibilityActionFailure``.
    ///
    /// An element that takes no value answers a request to set one like one that does, so a caller that needs the
    /// value to be there reads it afterwards.
    func perform(
        _ action: SimulatorAccessibilityAction, inProcess processIdentifier: Int32,
        on choose: ([SimulatorAccessibilityElement]) -> Int?
    ) throws {
        var elements: [SimulatorAccessibilityElement] = []
        var objects: [AnyObject] = []
        var ancestors: Set<Identity> = []
        if let root = try result(of: .application, nil, ["pid": processIdentifier]) {
            try list(root as AnyObject, into: &elements, &objects, ancestors: &ancestors)
        }
        guard let chosen = choose(elements), objects.indices.contains(chosen) else {
            throw SimulatorAccessibilityActionFailure.elementGone
        }
        let message =
            switch action {
            case .press: Message(request: .action, element: objects[chosen], action: Self.press)
            case .setValue(let value):
                Message(
                    request: .setAttribute, element: objects[chosen], parameters: ["value": value],
                    attribute: UInt64(Attribute.value.rawValue))
            }
        let answer = try send(message)
        guard answer.error != Self.noElement else { throw SimulatorAccessibilityActionFailure.elementGone }
        guard answer.error == 0 else { throw SimulatorAccessibilityFailure(code: answer.error) }
        if action == .press, (answer.result as? NSNumber)?.boolValue != true {
            throw SimulatorAccessibilityActionFailure.refused
        }
    }

    /// The result of a request, or nil where the guest has no element for it.
    private func result(of request: Request, _ element: AnyObject?, _ parameters: [String: Any]) throws -> Any? {
        let answer = try send(Message(request: request, element: element, parameters: parameters))
        guard answer.error != Self.noElement else { return nil }
        guard answer.error == 0 else { throw SimulatorAccessibilityFailure(code: answer.error) }
        return answer.result
    }

    /// What an element answers about itself, with the translation objects of its children if it is asked for them.
    /// Nothing for an element that is gone by the time it is asked.
    private func description(
        of object: AnyObject, identity: Identity, withChildren: Bool
    ) throws -> (element: SimulatorAccessibilityElement, children: [AnyObject])? {
        var attributes = Attribute.allCases
        if !withChildren { attributes.removeAll { $0 == .children } }
        let asked = ["attributes": attributes.map { NSNumber(value: $0.rawValue) }]
        guard let answer = try result(of: .attributes, object, asked) as? NSDictionary else { return nil }
        func value(_ attribute: Attribute) -> Any? { answer[NSNumber(value: attribute.rawValue)] }
        func text(_ attribute: Attribute) -> String? {
            switch value(attribute) {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        let element = SimulatorAccessibilityElement(
            role: (value(.role) as? NSNumber).flatMap { SimulatorAccessibilityElement.Role(rawValue: $0.intValue) },
            isSecureTextField: (value(.subrole) as? NSNumber)?.intValue == Self.secureTextField,
            isEnabled: (value(.isEnabled) as? NSNumber)?.boolValue ?? true,
            label: text(.label), value: text(.value), identifier: text(.identifier),
            frame: (value(.frame) as? NSValue)?.rectValue ?? .zero, processIdentifier: identity.processIdentifier,
            bundleIdentifier: text(.bundleIdentifier))
        return (element, value(.children) as? [AnyObject] ?? [])
    }

    /// Reads an element, or nothing for one that is gone by the time it is asked.
    private func read(
        _ object: AnyObject, descending: Bool, ancestors: inout Set<Identity>
    ) throws -> SimulatorAccessibilityElement? {
        // An element that lists one of its ancestors would never end the read.
        guard let identity = try identity(object), !ancestors.contains(identity),
            var (element, children) = try description(of: object, identity: identity, withChildren: descending)
        else { return nil }
        ancestors.insert(identity)
        defer { ancestors.remove(identity) }
        for child in children {
            if let read = try read(child, descending: true, ancestors: &ancestors) { element.children.append(read) }
        }
        return element
    }

    /// Lists an element and those under it in the order that they are read in, each without its children, with their
    /// translation objects.
    private func list(
        _ object: AnyObject, into elements: inout [SimulatorAccessibilityElement], _ objects: inout [AnyObject],
        ancestors: inout Set<Identity>
    ) throws {
        guard let identity = try identity(object), !ancestors.contains(identity),
            let (element, children) = try description(of: object, identity: identity, withChildren: true)
        else { return }
        elements.append(element)
        objects.append(object)
        ancestors.insert(identity)
        defer { ancestors.remove(identity) }
        for child in children { try list(child, into: &elements, &objects, ancestors: &ancestors) }
    }
}

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
        role: Role?, isSecureTextField: Bool = false, label: String? = nil, value: String? = nil,
        identifier: String? = nil, frame: CGRect, processIdentifier: Int32, bundleIdentifier: String? = nil,
        children: [SimulatorAccessibilityElement] = []
    ) {
        self.role = role
        self.isSecureTextField = isSecureTextField
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

/// Reads elements through the accessibility translator's requests to one device.
///
/// A request names no client, so an app answers with the elements that VoiceOver reads: those accessible on the
/// screen now. A client that asks for the automation tree also gets elements that a sheet covers.
struct SimulatorAccessibilityReader {
    /// A translation object's process and its number within that process, which together name one element.
    struct Identity: Hashable {
        let processIdentifier: Int32
        let objectID: UInt64
    }

    /// The translator's request types that a read sends.
    enum Request: UInt64 {
        case frontmostApplication = 4
        case attributes = 5
        case hitTest = 6
    }

    /// The translator's attribute numbers that a read asks for.
    private enum Attribute: Int, CaseIterable {
        case bundleIdentifier = 6
        case children = 8
        case frame = 21
        case identifier = 25
        case label = 33
        case role = 45
        case subrole = 51
        case value = 53
    }

    /// The translator's subrole number for a secure text field.
    private static let secureTextField = 5
    /// The translator's error number for nothing accessible at a point, or an element that is gone.
    private static let noElement: UInt64 = 8

    /// What the guest answered: the translator's error number, 0 for none, and the response's result.
    struct Answer {
        var error: UInt64 = 0
        var result: Any?
    }

    /// Sends a request about `element`, a translation object, or about none, and waits for the guest's answer.
    let send: (_ request: Request, _ element: AnyObject?, _ parameters: [String: Any]) throws -> Answer
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

    /// The result of a request, or nil where the guest has no element for it.
    private func result(of request: Request, _ element: AnyObject?, _ parameters: [String: Any]) throws -> Any? {
        let answer = try send(request, element, parameters)
        guard answer.error != Self.noElement else { return nil }
        guard answer.error == 0 else { throw SimulatorAccessibilityFailure(code: answer.error) }
        return answer.result
    }

    /// Reads an element, or nothing for one that is gone by the time it is asked.
    private func read(
        _ object: AnyObject, descending: Bool, ancestors: inout Set<Identity>
    ) throws -> SimulatorAccessibilityElement? {
        // An element that lists one of its ancestors would never end the read.
        guard let identity = try identity(object), !ancestors.contains(identity) else { return nil }
        var attributes = Attribute.allCases
        if !descending { attributes.removeAll { $0 == .children } }
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
        var element = SimulatorAccessibilityElement(
            role: (value(.role) as? NSNumber).flatMap { SimulatorAccessibilityElement.Role(rawValue: $0.intValue) },
            isSecureTextField: (value(.subrole) as? NSNumber)?.intValue == Self.secureTextField,
            label: text(.label), value: text(.value), identifier: text(.identifier),
            frame: (value(.frame) as? NSValue)?.rectValue ?? .zero, processIdentifier: identity.processIdentifier,
            bundleIdentifier: text(.bundleIdentifier))
        ancestors.insert(identity)
        defer { ancestors.remove(identity) }
        for child in value(.children) as? [AnyObject] ?? [] {
            if let read = try read(child, descending: true, ancestors: &ancestors) { element.children.append(read) }
        }
        return element
    }
}

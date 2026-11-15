import CoreGraphics
import Foundation
@testable import NeoSimulatorDeviceIO
import Testing

@Suite
struct SimulatorAccessibilityTests {
    /// Stands for a translation object: an element of a guest process and what it answers.
    private final class Element: NSObject {
        let processIdentifier: Int32
        let objectID: UInt64
        /// The answer by attribute number, or nil for an element that is gone when it is asked.
        var attributes: [Int: Any]?
        /// The translator's error number that asking for the attributes answers with.
        var error: UInt64 = 0

        init(_ processIdentifier: Int32, _ objectID: UInt64, _ attributes: [Int: Any]?) {
            self.processIdentifier = processIdentifier
            self.objectID = objectID
            self.attributes = attributes
        }
    }

    /// A translator that answers for `frontmost`, for the element at any point, `hit`, and for the application of any
    /// process, `application`.
    private final class Translator {
        var frontmost: Element?
        var hit: Element?
        var application: Element?
        /// Whether an element takes a press.
        var takesPress = true
        /// The actions that elements took, each with its element's number.
        var performed: [String] = []
        /// The attribute numbers that each request for attributes asked for.
        var asked: [[Int]] = []
        var points: [CGPoint] = []

        var reader: SimulatorAccessibilityReader {
            SimulatorAccessibilityReader(
                send: { [self] message in
                    let (element, parameters) = (message.element, message.parameters)
                    switch message.request {
                    case .application: return .init(result: application)
                    case .action:
                        guard takesPress, let element = element as? Element else { return .init(result: false) }
                        performed.append("action \(message.action) on \(element.objectID)")
                        return .init(result: true)
                    case .setAttribute:
                        guard let element = element as? Element else { return .init(error: 8) }
                        performed.append(
                            "set \(message.attribute) of \(element.objectID) to \(parameters["value"] ?? "nothing")")
                        return .init()
                    case .frontmostApplication: return .init(result: frontmost)
                    case .hitTest:
                        points.append((parameters["point"] as? NSValue)?.pointValue ?? .zero)
                        // The guest's error for nothing accessible at a point.
                        return hit.map { .init(result: $0) } ?? .init(error: 8)
                    case .attributes:
                        let numbers = (parameters["attributes"] as? [NSNumber] ?? []).map(\.intValue)
                        asked.append(numbers)
                        guard let element = element as? Element, let attributes = element.attributes else {
                            return .init()
                        }
                        let answer = NSMutableDictionary()
                        for number in numbers { answer[NSNumber(value: number)] = attributes[number] }
                        return .init(error: element.error, result: answer)
                    }
                },
                identity: { object in
                    (object as? Element).map { .init(processIdentifier: $0.processIdentifier, objectID: $0.objectID) }
                })
        }
    }

    // The translator's attribute numbers.
    private let bundle = 6, children = 8, frame = 21, identifier = 25, enabled = 27, label = 33, role = 45
    private let subrole = 51, value = 53

    @Test func theFrontmostApplicationIsReadWithItsElements() throws {
        let translator = Translator()
        let password = Element(
            7, 2,
            [
                role: 15, subrole: 5, value: "••••", identifier: "password",
                frame: NSValue(rect: CGRect(x: 16, y: 441, width: 370, height: 34)),
            ])
        let application = Element(7, 1, [role: 1, label: "Example", bundle: "com.example.app"])
        // A slider answers a number, an element can be gone when it is asked, and one can list its ancestor.
        let slider = Element(7, 3, [role: 13, value: NSNumber(value: 0.5)])
        slider.attributes?[children] = [application]
        application.attributes?[children] = [password, Element(7, 4, nil), slider]
        translator.frontmost = application

        let read = try #require(try translator.reader.frontmostApplication())
        #expect(
            read
                == SimulatorAccessibilityElement(
                    role: .application, label: "Example", frame: .zero, processIdentifier: 7,
                    bundleIdentifier: "com.example.app",
                    children: [
                        SimulatorAccessibilityElement(
                            role: .textField, isSecureTextField: true, value: "••••", identifier: "password",
                            frame: CGRect(x: 16, y: 441, width: 370, height: 34), processIdentifier: 7),
                        SimulatorAccessibilityElement(role: .slider, value: "0.5", frame: .zero, processIdentifier: 7),
                    ]))
    }

    @Test func theElementAtAPointIsReadWithoutItsChildren() throws {
        let translator = Translator()
        translator.hit = Element(9, 1, [role: 2, label: "Continue", children: [Element(9, 2, [role: 14])]])

        let read = try translator.reader.element(at: CGPoint(x: 275, y: 529))
        #expect(
            read == SimulatorAccessibilityElement(role: .button, label: "Continue", frame: .zero, processIdentifier: 9))
        #expect(translator.points == [CGPoint(x: 275, y: 529)])
        #expect(translator.asked.count == 1 && translator.asked[0].contains(children) == false)
        #expect(try Translator().reader.element(at: .zero) == nil)
    }

    @Test func anActionGoesToTheElementThatIsChosenFromWhatTheAppHasNow() throws {
        let translator = Translator()
        let field = Element(
            7, 2, [role: 15, subrole: 5, identifier: "password", frame: NSValue(rect: CGRect(x: 16, y: 441, width: 370, height: 34))])
        // The app has disabled the button.
        let button = Element(7, 3, [role: 2, label: "Sign In", enabled: false])
        translator.application = Element(7, 1, [role: 1, children: [field, button]])
        #expect(try translator.reader.application(processIdentifier: 7)?.children.count == 2)

        // The elements are listed in the order that they are read in, each without its children.
        var listed: [SimulatorAccessibilityElement] = []
        try translator.reader.perform(.setValue("s3cret"), inProcess: 7) { elements in
            listed = elements
            return elements.firstIndex { $0.isSecureTextField }
        }
        #expect(listed.map(\.role) == [.application, .textField, .button] && listed.allSatisfy(\.children.isEmpty))
        #expect(listed.map(\.isEnabled) == [true, true, false])
        try translator.reader.perform(.press, inProcess: 7) { $0.firstIndex { $0.label == "Sign In" } }
        // The value attribute, and the action that presses.
        #expect(translator.performed == ["set 53 of 2 to s3cret", "action 5 on 3"])

        translator.takesPress = false
        #expect(throws: SimulatorAccessibilityActionFailure.refused) {
            try translator.reader.perform(.press, inProcess: 7) { $0.firstIndex { $0.label == "Sign In" } }
        }
        // The app no longer has the element.
        #expect(throws: SimulatorAccessibilityActionFailure.elementGone) {
            try translator.reader.perform(.setValue("s3cret"), inProcess: 7) { $0.firstIndex { $0.role == .slider } }
        }
        #expect(translator.performed.count == 2)
    }

    @Test func anElementThatAnswersWithAnErrorFailsTheRead() throws {
        let translator = Translator()
        let field = Element(7, 2, [role: 15])
        // What the guest answers for an app that does not respond.
        field.error = 17
        translator.frontmost = Element(7, 1, [role: 1, children: [field]])
        #expect(throws: SimulatorAccessibilityFailure(code: 17)) { try translator.reader.frontmostApplication() }
    }
}

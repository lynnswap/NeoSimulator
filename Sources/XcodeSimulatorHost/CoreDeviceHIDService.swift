import ABIBridge
import AppKit

/// One native UniversalHID service. Its owner builds the reports, orders their sends, and tracks what they hold.
@MainActor
final class CoreDeviceHIDService {
    /// CoreDevice consumes its bundled module; DeviceKit can also load the system module with the same name.
    static let universalHIDURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/UniversalHID.framework/Versions/A/UniversalHID")

    private let sendNative: (NativeSwiftValue) throws -> Void
    private let resetNative: () throws -> Void
    private let removeNative: (() async throws -> Void)?
    private(set) var isRemoved = false

    /// A nil `remove` marks a service the device owns, which stopping leaves on the device.
    init(send: @escaping (NativeSwiftValue) throws -> Void, reset: @escaping () throws -> Void,
         remove: (() async throws -> Void)?) {
        sendNative = send
        resetNative = reset
        removeNative = remove
    }

    /// Resolves a type from CoreDevice's own UniversalHID module.
    static func universalHIDType(_ name: String, runtime: ABIRuntime) throws -> NativeSwiftType {
        try CoreDeviceRemoteScreenDevice.load(universalHIDURL.path)
        return try runtime.resolveAndWait(.swift(.type("UniversalHID." + name)), in: .path(universalHIDURL), loading: .loadedOnly)
    }

    /// `HIDReport` wraps the report's `Data`; its exported members pass those two words directly,
    /// while native value witnesses still own and copy the payload.
    static func reportABI(runtime: ABIRuntime) throws -> (type: NativeSwiftType, abi: NativeType) {
        let type = try universalHIDType("HIDReport", runtime: runtime)
        return (type, try .structure(named: type.name, fields: [.uint64, .uint64]))
    }

    /// Creates the service `descriptor` describes. Its reports must come from CoreDevice's UniversalHID module.
    static func connect(remote: CoreDeviceRemoteScreenDevice, descriptor: NativeSwiftValue) async throws -> CoreDeviceHIDService {
        try await open(.created(descriptor: descriptor), remote: remote, failure: nativeFailure(runtime: remote.runtime))
    }

    /// Uses the service the device lists for trackpad gestures over its touchscreen. Device Hub sends to it without
    /// creating it, so stopping it leaves the service on the device.
    static func touchscreenGesture(remote: CoreDeviceRemoteScreenDevice) async throws -> CoreDeviceHIDService {
        try await open(.touchscreenGesture, remote: remote, failure: nativeFailure(runtime: remote.runtime))
    }

    private enum Service {
        case created(descriptor: NativeSwiftValue)
        case touchscreenGesture
    }

    private static func nativeFailure(runtime: ABIRuntime) throws -> any Error {
        let errorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.CoreDeviceError")))
        let readError = try errorType.resolveAndWait(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        guard let failure = try unsafe readError.unsafeInvoke().withCopy({ $0 as? any Error }) else {
            throw CLIError.io("remote-hid-service", "The native HID service error type could not be resolved.")
        }
        return failure
    }

    private static func open<Failure: Error>(_ service: Service, remote: CoreDeviceRemoteScreenDevice,
                                            failure: Failure) async throws -> CoreDeviceHIDService {
        let runtime = remote.runtime
        let implementation = try await remote.implementation(capability: "UniversalHIDServiceCapability",
                                                             feature: CoreDeviceScreenInput.universalHIDFeature)
        let descriptorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let serviceIDType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceID")))
        let report = try reportABI(runtime: runtime)
        let abis: [NativeSwiftType: NativeType] = [
            report.type: report.abi,
            descriptorType: try .opaque(named: descriptorType.name),
            serviceIDType: try .opaque(named: serviceIDType.name),
        ]
        // CoreDevice also declares `Swift.UInt64` service-ID overloads of `send` and `resetGestureState`, which runtime-value
        // arguments cannot tell apart by labels. Every requirement names the `HIDServiceID` declaration that `createService` returns.
        let send = try implementation.type.resolveAndWait(.swift(.method(
            "CoreDevice.UniversalHIDService.send(report: UniversalHID.HIDReport, to: CoreDevice.HIDServiceID) throws(CoreDevice.CoreDeviceError) -> ()",
            as: ((NativeSwiftValue, NativeSwiftValue) throws(Failure) -> Void).self, valueABIs: abis)))
        let reset = try implementation.type.resolveAndWait(.swift(.method(
            "CoreDevice.UniversalHIDService.resetGestureState(service: CoreDevice.HIDServiceID) throws(CoreDevice.CoreDeviceError) -> ()",
            as: ((NativeSwiftValue) throws(Failure) -> Void).self, valueABIs: abis)))
        let serviceID: NativeSwiftValue
        var remove: (() async throws -> Void)?
        switch service {
        case .created(let descriptor):
            let create = try implementation.type.resolveAndWait(.swift(.method(
                "CoreDevice.UniversalHIDService.createService(descriptor: CoreDevice.HIDServiceDescriptor) async throws(CoreDevice.CoreDeviceError) -> CoreDevice.HIDServiceID",
                as: ((NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
            let removal = try implementation.type.resolveAndWait(.swift(.method(
                "CoreDevice.UniversalHIDService.remove(service: CoreDevice.HIDServiceID) async throws(CoreDevice.CoreDeviceError) -> ()",
                as: ((NativeSwiftValue) async throws(Failure) -> Void).self, valueABIs: abis)))
            let created = try await unsafe create.unsafeInvoke(on: implementation, descriptor)
            serviceID = created
            remove = { try await unsafe removal.unsafeInvoke(on: implementation, created) }
        case .touchscreenGesture:
            // CoreDeviceUtilities declares the device's standard service IDs.
            try CoreDeviceRemoteScreenDevice.load(NativeKeyboardBindings.coreDeviceUtilitiesPath)
            let gesture = try serviceIDType.resolveAndWait(.swift(.staticGetter("touchscreenGesture",
                as: (() -> NativeSwiftValue).self, valueABIs: abis)))
            // The device lists the services it accepts reports for; Device Hub sends only to listed ones.
            let exists = try implementation.type.resolveAndWait(.swift(.method(
                "(extension in CoreDevice):CoreDevice.UniversalHIDService.serviceExists(CoreDevice.HIDServiceID) async throws(CoreDevice.CoreDeviceError) -> Swift.Bool",
                as: ((NativeSwiftValue) async throws(Failure) -> Bool).self, valueABIs: abis)))
            serviceID = try unsafe gesture.unsafeInvoke()
            guard try await unsafe exists.unsafeInvoke(on: implementation, serviceID) else {
                throw CLIError.unavailable("remote-gesture-service", "The device does not accept trackpad gestures.")
            }
        }
        // The returned service has an owner before cancellation can abandon it.
        return CoreDeviceHIDService(send: { report in
            try unsafe send.unsafeInvoke(on: implementation, report, serviceID)
        }, reset: { try unsafe reset.unsafeInvoke(on: implementation, serviceID) }, remove: remove)
    }

    static func touchscreenDescriptor(displayID: UInt32, uniqueID: String, runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let serviceType = try runtime.resolveAndWait(.swift(.type("CoreDeviceUtilities.HIDServiceType")))
        let descriptorType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let array = try runtime.resolveAndWait(.swift(.type("Swift.Array", genericArguments: [.type((displayID: UInt32, uniqueID: String?).self)])))
        let read = try array.resolveAndWait(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        let payload = try unsafe read.unsafeInvoke(on: [(displayID: displayID, uniqueID: Optional(uniqueID))], 0)
        let screen = try await serviceType.makeEnumCase(named: "touchscreen", payload: payload)
        let serviceIDType = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDServiceID")))
        let abis: [NativeSwiftType: NativeType] = [serviceType: try .opaque(named: serviceType.name),
            descriptorType: try .opaque(named: descriptorType.name), serviceIDType: try .opaque(named: serviceIDType.name)]
        let descriptor = try serviceType.resolveAndWait(.swift(.method("descriptor()", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[serviceType])))
        let serviceID = try serviceType.resolveAndWait(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[serviceType])))
        let setServiceID = try descriptorType.resolveAndWait(.swift(.setter("serviceID", as: ((NativeSwiftValue) -> Void).self,
            valueABIs: abis, receiverABI: abis[descriptorType])))
        let result = try unsafe descriptor.unsafeInvoke(on: screen)
        // descriptor() supplies the service properties; its ID starts unassigned.
        try unsafe setServiceID.unsafeInvoke(on: result, serviceID.unsafeInvoke(on: screen))
        return result
    }

    func send(_ report: NativeSwiftValue) throws {
        guard !isRemoved else { throw CLIError.unavailable("remote-hid-service", "The HID service has ended.") }
        try sendNative(report)
    }

    /// Ends the gestures the service holds on the device, as Device Hub's HID reset does for each of its services.
    func resetGestures() throws {
        guard !isRemoved else { throw CLIError.unavailable("remote-hid-service", "The HID service has ended.") }
        try resetNative()
    }

    func stop() async throws {
        guard !isRemoved else { return }
        var failure: (any Error)?
        do { try resetNative() } catch { failure = error }
        do { try await removeNative?(); isRemoved = true }
        catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
        if let failure { throw failure }
    }
}

/// Builds SDK-owned reports without opening a device or HID service.
@MainActor
struct CoreDeviceDigitizerReports {
    let abis: [NativeSwiftType: NativeType]
    private let build: (CGPoint, CGPoint?, RemoteDeviceTouchPhase, RemoteDeviceTouchEdge) throws -> NativeSwiftValue

    init(runtime: ABIRuntime) throws {
        let report = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let reportType = report.type
        let digitizerType = try CoreDeviceHIDService.universalHIDType("DigitizerReport", runtime: runtime)
        let contactType = try CoreDeviceHIDService.universalHIDType("DigitizerContact", runtime: runtime)
        let descriptorType = try CoreDeviceHIDService.universalHIDType("HIDReportDescriptor", runtime: runtime)
        let reportIDType = try CoreDeviceHIDService.universalHIDType("ReportID", runtime: runtime)
        // These exported constructors pass the two-word Data representation directly;
        // native value witnesses still own and copy their payloads.
        abis = [
            descriptorType: try .opaque(named: descriptorType.name),
            reportType: report.abi,
            digitizerType: try .structure(named: digitizerType.name, fields: [.uint64, .uint64]),
            contactType: try .structure(named: contactType.name, fields: [.uint64, .uint64]),
            reportIDType: try .structure(named: reportIDType.name, fields: [.uint8]),
        ]
        let abis = self.abis
        let descriptor = try digitizerType.resolveAndWait(.swift(.staticGetter("descriptor", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let bitCount = try descriptorType.resolveAndWait(.swift(.method("reportBitCount(for:)", as: ((NativeSwiftValue) -> Int).self,
            valueABIs: abis, receiverABI: abis[descriptorType])))
        let reportID = try digitizerType.resolveAndWait(.swift(.staticGetter("reportID", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let bits = try unsafe bitCount.unsafeInvoke(on: descriptor.unsafeInvoke(), reportID.unsafeInvoke())
        let makeReport = try reportType.resolveAndWait(.swift(.initializer("init(bitCount:id:)",
            as: ((Int, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        let makeDigitizer = try digitizerType.resolveAndWait(.swift(.initializer("init(_report:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        let makeContact = try contactType.resolveAndWait(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let receiver = abis[digitizerType]!
        let maxContacts = try digitizerType.resolveAndWait(.swift(.setter("contactCountMaximum", as: ((UInt8) -> Void).self, valueABIs: abis, receiverABI: receiver)))
        let contactCount = try digitizerType.resolveAndWait(.swift(.setter("contactCount", as: ((UInt8) -> Void).self, valueABIs: abis, receiverABI: receiver)))
        let setContact = try digitizerType.resolveAndWait(.swift(.method("setContact(_:atIndex:)", as: ((NativeSwiftValue, Int) -> Void).self, valueABIs: abis, receiverABI: receiver, receiver: .mutating)))
        let identity = try digitizerType.resolveAndWait(.swift(.method("setContactIdentity(_:atIndex:)", as: ((UInt8, Int) -> Void).self, valueABIs: abis, receiverABI: receiver, receiver: .mutating)))
        let readReport = try digitizerType.resolveAndWait(.swift(.getter("report", as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: receiver)))
        let contactReceiver = abis[contactType]!
        let contactIndex = try contactType.resolveAndWait(.swift(.setter("index", as: ((Int) -> Void).self, valueABIs: abis, receiverABI: contactReceiver)))
        let x = try contactType.resolveAndWait(.swift(.setter("x", as: ((Double) -> Void).self, valueABIs: abis, receiverABI: contactReceiver)))
        let y = try contactType.resolveAndWait(.swift(.setter("y", as: ((Double) -> Void).self, valueABIs: abis, receiverABI: contactReceiver)))
        let touch = try contactType.resolveAndWait(.swift(.setter("touch", as: ((Bool) -> Void).self, valueABIs: abis, receiverABI: contactReceiver)))
        let range = try contactType.resolveAndWait(.swift(.setter("range", as: ((Bool) -> Void).self, valueABIs: abis, receiverABI: contactReceiver)))
        let edgeMethods = try Dictionary(uniqueKeysWithValues: ["top": "Up", "bottom": "Down", "left": "Left", "right": "Right"].map { edge, suffix in
            (edge, try digitizerType.resolveAndWait(.swift(.method("setContactSwipe\(suffix)(_:atIndex:)",
                as: ((Bool, Int) -> Void).self, valueABIs: abis, receiverABI: receiver, receiver: .mutating))))
        })
        build = { point, second, phase, edge in
            let initial = try unsafe makeReport.unsafeInvoke(bits, reportID.unsafeInvoke())
            let report = try unsafe makeDigitizer.unsafeInvoke(initial)
            try unsafe maxContacts.unsafeInvoke(on: report, 2)
            let points = [point] + (second.map { [$0] } ?? [])
            try unsafe contactCount.unsafeInvoke(on: report, UInt8(points.count))
            for (index, point) in points.enumerated() {
                let contact = try unsafe makeContact.unsafeInvoke()
                try unsafe contactIndex.unsafeInvoke(on: contact, index + 1)
                try unsafe x.unsafeInvoke(on: contact, Double(point.x))
                try unsafe y.unsafeInvoke(on: contact, Double(point.y))
                try unsafe touch.unsafeInvoke(on: contact, phase != .ended)
                try unsafe range.unsafeInvoke(on: contact, phase != .ended)
                try unsafe setContact.unsafeInvoke(on: report, contact, index)
                try unsafe identity.unsafeInvoke(on: report, UInt8(index + 1), index)
                if let method = edgeMethods[edge.rawValue] { try unsafe method.unsafeInvoke(on: report, true, index) }
            }
            let result = try unsafe readReport.unsafeInvoke(on: report)
            return result
        }
    }

    func make(point: CGPoint, second: CGPoint?, phase: RemoteDeviceTouchPhase, edge: RemoteDeviceTouchEdge) throws -> NativeSwiftValue {
        try build(point, second, phase, edge)
    }
}

/// Translates AppKit events into reports with UniversalHIDKit's `EventObserver`, as Device Hub does. UniversalHIDKit uses
/// the system UniversalHID module, while CoreDevice consumes its bundled module of the same name. Each report crosses
/// between them as its bytes, never as the other module's value.
@MainActor
struct CoreDeviceEventReports {
    static let systemUniversalHIDURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHID.framework/Versions/A/UniversalHID")
    static let universalHIDKitURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHIDKit.framework/Versions/A/UniversalHIDKit")

    /// An `EventObserver` with its own event state, such as the keys one keyboard holds.
    struct Translator {
        fileprivate let observer: NativeSwiftValue
        fileprivate let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]

        func reports(for event: NSEvent) throws -> [NativeSwiftValue] { try translate(observer, event) }
    }

    private let makeObserver: () throws -> NativeSwiftValue
    private let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]

    /// Translates the events of `eventType`, the name of a `UniversalHID.HIDEventType` member such as `keyboard`.
    init(runtime: ABIRuntime, eventType name: String) async throws {
        try CoreDeviceRemoteScreenDevice.load(Self.universalHIDKitURL.path)
        let system = Self.systemUniversalHIDURL
        let eventType = try await runtime.resolve(.swift(.type("UniversalHID.HIDEventType")), in: .path(system), loading: .loadedOnly)
        let maskType = try await runtime.resolve(.swift(.type("UniversalHID.HIDEventMask")), in: .path(system), loading: .loadedOnly)
        let observerType = try await runtime.resolve(.swift(.type("UniversalHIDKit.EventObserver",
            genericArguments: [.type(NSEvent.self)])), in: .path(Self.universalHIDKitURL), loading: .loadedOnly)
        let systemReport = try await runtime.resolve(.swift(.type("UniversalHID.HIDReport")), in: .path(system), loading: .loadedOnly)
        let coreDeviceReport = try CoreDeviceHIDService.reportABI(runtime: runtime)
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        let dataABI = try NativeType.structure(named: data.name, fields: [.uint64, .uint64])
        // These single-field and Data-wrapping values pass their stored words directly, as DeviceKit passes them.
        // Each map names one module's types: a type both modules define resolves to the map's entry.
        let systemReportABI = try NativeType.structure(named: systemReport.name, fields: [.uint64, .uint64])
        let systemABIs: [NativeSwiftType: NativeType] = [
            eventType: try .structure(named: eventType.name, fields: [.uint32]),
            maskType: try .structure(named: maskType.name, fields: [.uint64]),
            systemReport: systemReportABI,
            data: dataABI,
        ]
        let member = try await eventType.resolve(.swift(.staticGetter(name, as: (() -> NativeSwiftValue).self,
            valueABIs: systemABIs)))
        let maskValue = try await eventType.resolve(.swift(.getter("maskValue", as: (() -> UInt).self,
            valueABIs: systemABIs, receiverABI: systemABIs[eventType])))
        let makeMask = try await maskType.resolve(.swift(.initializer("init(rawValue:)", as: ((UInt) -> NativeSwiftValue).self,
            valueABIs: systemABIs)))
        let makeObserver = try await observerType.resolve(.swift(.initializer("init(eventMask:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: systemABIs)))
        let process = try await observerType.resolve(.swift(.method("processEvent(_:)", as: ((NSEvent) -> NativeSwiftValue).self,
            valueABIs: systemABIs)))
        let readData = try await systemReport.resolve(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: systemABIs, receiverABI: systemReportABI)))
        let makeReport = try await coreDeviceReport.type.resolve(.swift(.initializer("init(data:)",
            as: ((Data) -> NativeSwiftValue).self, valueABIs: [coreDeviceReport.type: coreDeviceReport.abi, data: dataABI])))
        let mask = try unsafe maskValue.unsafeInvoke(on: member.unsafeInvoke())
        // The initializer consumes its mask, so each observer gets its own.
        let observe = { try unsafe makeObserver.unsafeInvoke(makeMask.unsafeInvoke(mask)) }

        // A result is an array of (report, senderID) whose element type comes from the system module. An event of
        // any type yields that array, including one the observer does not translate.
        let probe = try unsafe process.unsafeInvoke(on: observe(), Self.sampleKey(.keyDown))
        let count = try await probe.type.resolve(.swift(.getter("count", as: (() -> Int).self)))
        let element = try await probe.type.resolve(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        translate = { observer, event in
            let results = try unsafe process.unsafeInvoke(on: observer, event)
            let reports = try unsafe count.unsafeInvoke(on: results)
            return try (0..<reports).map { index in
                let report = try unsafe element.unsafeInvoke(on: results, index).copyTupleElement(at: 0)
                guard report.type == systemReport else {
                    throw CLIError.unavailable("native-event-report", "UniversalHIDKit returned \(report.type.name) from "
                        + "\(String(describing: report.type.image)) instead of the system UniversalHID report.")
                }
                return try unsafe makeReport.unsafeInvoke(readData.unsafeInvoke(on: report))
            }
        }
        self.makeObserver = observe
    }

    func makeTranslator() throws -> Translator { Translator(observer: try makeObserver(), translate: translate) }

    static func sampleKey(_ type: NSEvent.EventType) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else {
            throw CLIError.software("native-keyboard-sample", "AppKit could not create a sample key event.")
        }
        return event
    }
}

import ABIBridge
import AppKit
import IOKit.hidsystem
import os

/// Forwards a simulator's Mac keyboard input through CoreDevice keyboard services that carry each Mac keyboard's
/// own HID properties. The guest derives a keyboard's hardware layout, such as JIS, from those properties, as it
/// does for Device Hub; SimulatorKit's keyboard messages carry none, so the guest reads them with a US layout.
@_spi(NeoSimulator)
@MainActor
public final class NativeDeviceKeyboard {
    /// Receives failures of input that was already accepted, such as a keyboard service that could not be created.
    public var onFailure: (any Error) -> Void = { _ in }
    private let transport: any NativeKeyboardTransport
    /// Mac keyboards by the registry ID of their HID service.
    private var keyboards: [UInt64: any NativeKeyboardService] = [:]
    /// Senders that are not Mac HID services, such as other processes' event sources. Their input counts as synthesized.
    private var unknownSenders: Set<UInt64> = []
    /// The Mac keyboard that last sent input. Synthesized input, including the modifier synchronization and releases
    /// that `DisplayKeyboardInput` and Capture Keyboard send, belongs to it, so it reaches the keyboard holding the keys.
    private var activeSender: UInt64?
    /// Carries synthesized input before any Mac keyboard sends input, as Device Hub's main keyboard does.
    private var mainKeyboard: (any NativeKeyboardService)?
    /// Keyboards whose guest service could not be removed, which the next removal retries.
    private var unremoved: [any NativeKeyboardService] = []
    private var enabledDisplays: Set<ObjectIdentifier> = []
    private var modifierMonitor: Any?
    private var lastOperation: Task<Void, Never>?
    private var isStopped = false

    /// Connects to the simulator's CoreDevice record, which exists only for the default device set.
    /// A keyboard's guest service is created with its first report.
    public static func connect(simulatorUDID: String) async throws -> NativeDeviceKeyboard {
        guard let identifier = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: simulatorUDID) else {
            throw CLIError.unavailable("native-keyboard", "The simulator is not available in CoreDevice.")
        }
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: identifier)
        guard try remote.supports(CoreDeviceScreenInput.universalHIDFeature) else {
            throw CLIError.unavailable("native-keyboard", "The simulator does not expose CoreDevice's HID services.")
        }
        try Task.checkCancellation()
        return NativeDeviceKeyboard(transport: try await CoreDeviceKeyboardTransport(remote: remote))
    }

    init(transport: any NativeKeyboardTransport) {
        self.transport = transport
    }

    isolated deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    /// Gives one of the device's displays the Mac's keyboard, as SimulatorKit's keyboard does while it is enabled.
    /// Modifier changes are observed app-wide while any display has it, including synthesized ones.
    public func setEnabled(_ enabled: Bool, for display: AnyObject) {
        let identifier = ObjectIdentifier(display)
        if enabled, !isStopped { enabledDisplays.insert(identifier) } else { enabledDisplays.remove(identifier) }
        if enabledDisplays.isEmpty {
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
            modifierMonitor = nil
        } else if modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    public func isEnabled(for display: AnyObject) -> Bool {
        enabledDisplays.contains(ObjectIdentifier(display))
    }

    /// Forwards a key-down, key-up, or modifier change in order. Repeated key-downs are left to the guest's
    /// key repeat, as for a hardware keyboard.
    public func handle(_ event: NSEvent) {
        guard !isStopped, [.keyDown, .keyUp, .flagsChanged].contains(event.type),
              event.type != .keyDown || !event.isARepeat else { return }
        let keyboard: any NativeKeyboardService
        do {
            let sender = try transport.sender(of: event)
            if let macKeyboard = try macKeyboard(sender) {
                activeSender = sender
                if let mainKeyboard {
                    // The Mac keyboard now owns the input. Removing the main keyboard releases what it held.
                    self.mainKeyboard = nil
                    enqueue { [weak self] in
                        do { try await mainKeyboard.stop() } catch { self?.unremoved.append(mainKeyboard); self?.onFailure(error) }
                    }
                }
                keyboard = macKeyboard
            } else if let activeSender, let macKeyboard = try macKeyboard(activeSender) {
                keyboard = macKeyboard
            } else {
                keyboard = try mainKeyboard ?? transport.makeMainKeyboard()
                mainKeyboard = keyboard
            }
        } catch { onFailure(error); return }
        enqueue { [weak self] in
            do { try await keyboard.send(event) } catch { self?.onFailure(error) }
        }
    }

    /// Removes every keyboard service so the guest no longer reports a connected hardware keyboard; later input
    /// creates them again with released keys. A service that could not be removed is retried by the next removal.
    public func removeServices() async throws {
        let removing = unremoved + keyboards.keys.sorted().compactMap { keyboards[$0] } + (mainKeyboard.map { [$0] } ?? [])
        unremoved = []
        keyboards = [:]
        mainKeyboard = nil
        try await enqueue { [weak self] in
            var failures: [String] = []
            for keyboard in removing {
                do { try await keyboard.stop() } catch {
                    self?.unremoved.append(keyboard)
                    failures.append(error.localizedDescription)
                }
            }
            if !failures.isEmpty { throw CLIError.io("native-keyboard-removal", failures.joined(separator: "\n")) }
        }.value
    }

    /// Ends input and removes the services when the device's displays disconnect.
    public func stop() async throws {
        isStopped = true
        enabledDisplays.removeAll()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        try await removeServices()
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            try await operation()
        }
        lastOperation = Task { _ = await task.result }
        return task
    }

    /// The keyboard of a Mac HID service, or nil for synthesized input and senders that are not Mac HID services.
    private func macKeyboard(_ sender: UInt64) throws -> (any NativeKeyboardService)? {
        guard sender != 0, !unknownSenders.contains(sender) else { return nil }
        if let keyboard = keyboards[sender] { return keyboard }
        guard let keyboard = try transport.makeKeyboard(forSender: sender) else {
            unknownSenders.insert(sender)
            return nil
        }
        keyboards[sender] = keyboard
        return keyboard
    }
}

/// The Mac HID services that send keyboard input and the guest keyboards that receive it.
@MainActor
protocol NativeKeyboardTransport: AnyObject {
    /// The registry ID of the Mac HID service that produced the event, or 0 for a synthesized event.
    func sender(of event: NSEvent) throws -> UInt64
    /// A guest keyboard described by the Mac HID service `sender`, or nil when no such service exists.
    func makeKeyboard(forSender sender: UInt64) throws -> (any NativeKeyboardService)?
    /// The generic guest keyboard that carries synthesized input before any Mac keyboard sends input.
    func makeMainKeyboard() throws -> any NativeKeyboardService
}

/// One guest keyboard with its own key and modifier state.
@MainActor
protocol NativeKeyboardService: AnyObject {
    /// Translates the event against this keyboard's state and sends any reports, creating the guest service
    /// with the first of them.
    func send(_ event: NSEvent) async throws
    /// Removes the guest service, which releases what it held.
    func stop() async throws
}

@MainActor
final class CoreDeviceKeyboardTransport: NativeKeyboardTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let bindings: NativeKeyboardBindings

    init(remote: CoreDeviceRemoteScreenDevice) async throws {
        self.remote = remote
        bindings = try await NativeKeyboardBindings(runtime: remote.runtime)
    }

    func sender(of event: NSEvent) throws -> UInt64 { try bindings.sender(of: event) }

    func makeKeyboard(forSender sender: UInt64) throws -> (any NativeKeyboardService)? {
        guard let properties = HostHIDService.properties(of: sender, keys: bindings.propertyKeys) else { return nil }
        return try CoreDeviceKeyboardService(remote: remote, source: "Mac HID service 0x\(String(sender, radix: 16))",
            descriptor: bindings.descriptor(serviceID: sender, properties: properties), bindings: bindings)
    }

    func makeMainKeyboard() throws -> any NativeKeyboardService {
        try CoreDeviceKeyboardService(remote: remote, source: "synthesized input",
            descriptor: bindings.mainKeyboardDescriptor(), bindings: bindings)
    }
}

@MainActor
private final class CoreDeviceKeyboardService: NativeKeyboardService {
    private static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "Keyboard")
    private let remote: CoreDeviceRemoteScreenDevice
    private let source: String
    private let descriptor: NativeSwiftValue
    private let identity: NativeKeyboardBindings.Identity
    private let translator: NativeKeyboardBindings.Translator
    private var service: CoreDeviceHIDService?

    init(remote: CoreDeviceRemoteScreenDevice, source: String, descriptor: NativeSwiftValue,
         bindings: NativeKeyboardBindings) throws {
        self.remote = remote
        self.source = source
        self.descriptor = descriptor
        identity = try bindings.identity(of: descriptor)
        translator = try bindings.makeTranslator()
    }

    func send(_ event: NSEvent) async throws {
        let reports = try translator.reports(for: event)
        guard !reports.isEmpty else { return }
        let service: CoreDeviceHIDService
        if let existing = self.service { service = existing } else {
            service = try await CoreDeviceHIDService.connect(remote: remote, descriptor: descriptor)
            self.service = service
            Self.logger.log("Created the guest keyboard service for \(self.source, privacy: .public): \(self.identity.description, privacy: .public)")
        }
        for report in reports { try service.send(report) }
    }

    func stop() async throws { try await service?.stop() }
}

/// UniversalHIDKit translates AppKit events with the system UniversalHID module, while CoreDevice consumes its
/// bundled module of the same name. Each report crosses between them as its bytes, never as the other module's value.
@MainActor
struct NativeKeyboardBindings {
    static let systemUniversalHIDURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHID.framework/Versions/A/UniversalHID")
    static let universalHIDKitURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHIDKit.framework/Versions/A/UniversalHIDKit")
    static let coreDeviceUtilitiesPath = "/Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities"

    /// An `EventObserver` with one keyboard's key and modifier state, converting its reports for CoreDevice.
    struct Translator {
        fileprivate let observer: NativeSwiftValue
        fileprivate let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]

        func reports(for event: NSEvent) throws -> [NativeSwiftValue] { try translate(observer, event) }
    }

    /// The layout properties a guest keyboard service carries, as the guest reads them.
    struct Identity: CustomStringConvertible {
        let product: String?
        let standardType: UInt8?
        let countryCode: UInt8?
        /// Whether the guest counts the service as a hardware keyboard.
        let isHardwareKeyboard: Bool

        var description: String {
            "product \(product ?? "unnamed"), StandardType \(standardType.map(String.init) ?? "none"), "
                + "CountryCode \(countryCode.map(String.init) ?? "none"), hardware keyboard \(isHardwareKeyboard)"
        }
    }

    /// The keys UniversalHID copies from a HID service into its properties.
    let propertyKeys: [String]
    private let readSender: NativeSwiftMethod<() -> UInt64>
    private let makeObserver: () throws -> NativeSwiftValue
    private let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]
    private let makeDescriptor: (UInt64, [String: Any]) throws -> NativeSwiftValue
    private let makeMainKeyboardDescriptor: () throws -> NativeSwiftValue
    private let identify: (NativeSwiftValue) throws -> Identity

    init(runtime: ABIRuntime) async throws {
        try CoreDeviceRemoteScreenDevice.load(Self.coreDeviceUtilitiesPath)
        try CoreDeviceRemoteScreenDevice.load(Self.universalHIDKitURL.path)
        let system = Self.systemUniversalHIDURL
        let sample = try Self.sampleKey(.keyDown)
        // NSEvent's NSEventProtocol conformance is in UniversalHIDKit; the getter binds through an event.
        readSender = try await runtime.object(sample).resolve(.swift(.getter(
            "(extension in UniversalHIDKit):UniversalHIDKit.NSEventProtocol.senderID.getter : Swift.UInt64",
            as: (() -> UInt64).self))).method

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
        let keyboard = try await eventType.resolve(.swift(.staticGetter("keyboard", as: (() -> NativeSwiftValue).self,
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
        let mask = try unsafe maskValue.unsafeInvoke(on: keyboard.unsafeInvoke())
        // The initializer consumes its mask, so each observer gets its own.
        let observe = { try unsafe makeObserver.unsafeInvoke(makeMask.unsafeInvoke(mask)) }

        // A result is an array of (report, senderID) whose element type comes from the system module.
        let probe = try unsafe process.unsafeInvoke(on: observe(), sample)
        let count = try await probe.type.resolve(.swift(.getter("count", as: (() -> Int).self)))
        let element = try await probe.type.resolve(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        let translate = { (observer: NativeSwiftValue, event: NSEvent) throws -> [NativeSwiftValue] in
            let results = try unsafe process.unsafeInvoke(on: observer, event)
            let reports = try unsafe count.unsafeInvoke(on: results)
            return try (0..<reports).map { index in
                let report = try unsafe element.unsafeInvoke(on: results, index).copyTupleElement(at: 0)
                guard report.type == systemReport else {
                    throw CLIError.unavailable("native-keyboard-report", "UniversalHIDKit returned \(report.type.name) from "
                        + "\(String(describing: report.type.image)) instead of the system UniversalHID report.")
                }
                return try unsafe makeReport.unsafeInvoke(readData.unsafeInvoke(on: report))
            }
        }
        // Converting a key press before any service exists proves the translation; without it, keys would vanish.
        guard try !translate(observe(), sample).isEmpty else {
            throw CLIError.unavailable("native-keyboard-report", "UniversalHIDKit did not report a key press.")
        }
        self.makeObserver = observe
        self.translate = translate

        let keyType = try CoreDeviceHIDService.universalHIDType("HIDServicePropertyKey", runtime: runtime)
        let allKeys = try await keyType.resolve(.swift(.staticGetter("allCases", as: (() -> NativeSwiftValue).self,
            valueABIs: [keyType: try .structure(named: keyType.name, fields: [.uint64, .uint64])])))
        guard let keys = try unsafe allKeys.unsafeInvoke().withCopy({ value in
            (value as? [Any])?.map { ($0 as? any RawRepresentable)?.rawValue as? String }
        }), !keys.isEmpty, !keys.contains(nil) else {
            throw CLIError.unavailable("native-keyboard-properties", "UniversalHID's service property keys could not be read.")
        }
        propertyKeys = keys.compactMap(\.self)

        let properties = try CoreDeviceHIDService.universalHIDType("HIDServiceProperties", runtime: runtime)
        let descriptorType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let descriptorABIs: [NativeSwiftType: NativeType] = [
            properties: try .structure(named: properties.name, fields: [.uint64, .uint64]),
            descriptorType: try .opaque(named: descriptorType.name),
        ]
        let propertiesABI = descriptorABIs[properties]
        let makeProperties = try await properties.resolve(.swift(.initializer("init(serviceID:properties:)",
            as: ((UInt64, [String: Any]) throws -> NativeSwiftValue).self, valueABIs: descriptorABIs)))
        let ignoresNaturalScrolling = try await properties.resolve(.swift(.setter("ignoresNaturalScrollingPreference",
            as: ((Bool?) -> Void).self, valueABIs: descriptorABIs, receiverABI: propertiesABI)))
        let pointerButtonMode = try await properties.resolve(.swift(.setter("pointerButtonMode",
            as: ((Int?) -> Void).self, valueABIs: descriptorABIs, receiverABI: propertiesABI)))
        let makeServiceDescriptor = try await descriptorType.resolve(.swift(.initializer("init(serviceProperties:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: descriptorABIs)))
        let receiver = descriptorABIs[descriptorType]
        let setSoftwareKeyboard = try await descriptorType.resolve(.swift(.method("setSoftwareKeyboard(_:)",
            as: ((Bool) -> Bool).self, valueABIs: descriptorABIs, receiverABI: receiver, receiver: .mutating)))
        // Mac input reaches the guest only while its hardware keyboard is connected. Device Hub then marks each
        // descriptor as a hardware keyboard, which turns its generic main keyboard from a software keyboard into one.
        let hardwareKeyboardDescriptor = { (descriptor: NativeSwiftValue) throws -> NativeSwiftValue in
            _ = try unsafe setSoftwareKeyboard.unsafeInvoke(on: descriptor, false)
            return descriptor
        }
        makeDescriptor = { serviceID, values in
            let value = try unsafe makeProperties.unsafeInvoke(serviceID, values)
            // Device Hub's service lookup also adjusts these; matching it keeps the guest's view of the keyboard the same.
            try unsafe ignoresNaturalScrolling.unsafeInvoke(on: value, true)
            try unsafe pointerButtonMode.unsafeInvoke(on: value, nil)
            return try hardwareKeyboardDescriptor(unsafe makeServiceDescriptor.unsafeInvoke(value))
        }
        let mainKeyboard = try await descriptorType.resolve(.swift(.staticMethod("mainKeyboard()",
            as: (() -> NativeSwiftValue).self, valueABIs: descriptorABIs)))
        makeMainKeyboardDescriptor = { try hardwareKeyboardDescriptor(unsafe mainKeyboard.unsafeInvoke()) }
        let standardType = try await descriptorType.resolve(.swift(.getter("keyboardStandardType", as: (() -> UInt8?).self,
            valueABIs: descriptorABIs, receiverABI: receiver)))
        let countryCode = try await descriptorType.resolve(.swift(.getter("keyboardCountryCode", as: (() -> UInt8?).self,
            valueABIs: descriptorABIs, receiverABI: receiver)))
        let hardwareKeyboard = try await descriptorType.resolve(.swift(.getter("isBackBoardHardwareKeyboard", as: (() -> Bool).self,
            valueABIs: descriptorABIs, receiverABI: receiver)))
        let product = try await descriptorType.resolve(.swift(.getter("product", as: (() -> String?).self,
            valueABIs: descriptorABIs, receiverABI: receiver)))
        identify = { descriptor in
            Identity(product: try unsafe product.unsafeInvoke(on: descriptor),
                     standardType: try unsafe standardType.unsafeInvoke(on: descriptor),
                     countryCode: try unsafe countryCode.unsafeInvoke(on: descriptor),
                     isHardwareKeyboard: try unsafe hardwareKeyboard.unsafeInvoke(on: descriptor))
        }
    }

    func sender(of event: NSEvent) throws -> UInt64 { try unsafe readSender.unsafeInvoke(on: event) }

    func makeTranslator() throws -> Translator { Translator(observer: try makeObserver(), translate: translate) }

    func descriptor(serviceID: UInt64, properties: [String: Any]) throws -> NativeSwiftValue {
        try makeDescriptor(serviceID, properties)
    }

    /// CoreDevice's generic keyboard descriptor, which Device Hub uses for synthesized input.
    func mainKeyboardDescriptor() throws -> NativeSwiftValue { try makeMainKeyboardDescriptor() }

    func identity(of descriptor: NativeSwiftValue) throws -> Identity { try identify(descriptor) }

    private static func sampleKey(_ type: NSEvent.EventType) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else {
            throw CLIError.software("native-keyboard-sample", "AppKit could not create a sample key event.")
        }
        return event
    }
}

/// The Mac's HID services, as UniversalHID reads one to describe it to a guest.
enum HostHIDService {
    /// Reads `keys` from the HID service whose registry ID is `sender`, as `HIDServiceProperties(service:)` does,
    /// or returns nil when no such service exists.
    static func properties(of sender: UInt64, keys: [String]) -> [String: Any]? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        guard let service = services.first(where: {
            (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value == sender
        }) else { return nil }
        var properties: [String: Any] = [:]
        for key in keys {
            if let value = IOHIDServiceClientCopyProperty(service, key as CFString) { properties[key] = value }
        }
        return properties
    }
}

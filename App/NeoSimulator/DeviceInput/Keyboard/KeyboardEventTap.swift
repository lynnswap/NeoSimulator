import AppKit
import IOKit.hidsystem

/// A synchronous filter: returning true consumes an event before AppKit handles shortcuts.
@MainActor
protocol KeyboardEventTap: AnyObject {
    func start(receive: @escaping @MainActor (CGEventType, CGEvent) -> Bool) throws
    func stop()
}

@MainActor
final class SystemKeyboardEventTap: KeyboardEventTap {
    private struct StartFailure: LocalizedError {
        let errorDescription: String?
        let recoverySuggestion: String?
    }

    private let applicationName: String
    private let access: () -> IOHIDAccessType
    private let createTap: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var receive: (@MainActor (CGEventType, CGEvent) -> Bool)?

    init(applicationName: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName,
         access: @escaping () -> IOHIDAccessType = { IOHIDCheckAccess(kIOHIDRequestTypePostEvent) },
         createTap: @escaping (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort? = { mask, callback, context in
             CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: callback, userInfo: context)
         }) {
        self.applicationName = applicationName
        self.access = access
        self.createTap = createTap
    }

    func start(receive: @escaping @MainActor (CGEventType, CGEvent) -> Bool) throws {
        self.receive = receive
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = createTap(CGEventMask(mask), { _, type, event, context in
                // The source is installed exclusively on the main run loop below.
                let consumed = MainActor.assumeIsolated {
                    guard let context else { return false }
                    let tap = Unmanaged<SystemKeyboardEventTap>.fromOpaque(context).takeUnretainedValue()
                    return tap.receive?(type, event) ?? false
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, Unmanaged.passUnretained(self).toOpaque()) else {
            self.receive = nil
            // A nil tap also has non-permission causes. Query access only to diagnose its failure.
            let authorization = access()
            if authorization == kIOHIDAccessTypeGranted {
                throw StartFailure(errorDescription: "Unable to Create Keyboard Event Tap.",
                    recoverySuggestion: "macOS reports keyboard event access is allowed for “\(applicationName)”. Try Capture Keyboard again. If it still fails, quit and reopen the app. You can still type in the focused device screen.")
            }
            let title = authorization == kIOHIDAccessTypeDenied
                ? "Keyboard Capture Access Was Denied."
                : "Keyboard Capture Access Is Not Authorized."
            throw StartFailure(errorDescription: title,
                recoverySuggestion: "Allow “\(applicationName)” in System Settings > Privacy & Security > Accessibility, then try Capture Keyboard again. You can still type in the focused device screen.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            self.receive = nil
            throw HostError.operation("Unable to Capture Keyboard. The keyboard event source could not be created.")
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        receive = nil
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        port = nil
    }

    isolated deinit { stop() }
}

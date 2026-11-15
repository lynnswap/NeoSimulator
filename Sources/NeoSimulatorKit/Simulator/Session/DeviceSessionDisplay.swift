import Foundation
import NeoSimulatorDeviceIO

/// A device's StandBy as its own service presents it, for a guest that presents StandBy only while that service holds it.
@MainActor
package protocol DeviceStandBy: AnyObject {
    /// Whether this holds StandBy presented. The guest shows it for as long as the device's state supports StandBy.
    var isPresented: Bool { get }
    /// Presents StandBy and holds it until `dismiss()`. Throws what the device refuses it with as it is, such as a pose
    /// that does not support StandBy.
    func present() async throws
    /// Lets go of StandBy. Does nothing when this holds none.
    func dismiss() throws
}

/// What a device session needs of a connected display, whatever draws it: the device's guest messages, its input and its
/// optional services. A presentation layer owns the views and frames of the display it implements this with.
@MainActor
package protocol DeviceSessionDisplay: AnyObject {
    var isBooted: Bool { get }
    /// Returns once the device reports that its guest has finished starting, which is when the guest's own services
    /// answer. Throws if the device stops or its boot ends unfinished; cancellation ends the wait.
    func waitForGuestStartup() async throws
    var captureDisplayID: UInt32? { get throws }
    func connectAppDisplay(uniqueID: String) async throws -> any DeviceSessionDisplay
    /// Current CoreSimulator backlight state: 2 on, 1 always-on dimmed, 0 off.
    /// Nil when unavailable.
    var backlightState: Int32? { get }
    /// Posts recording notifications consumed by the device plugin's toolbar.
    func announceRecording(started: Bool)
    /// Called on the main actor when the screen's properties change, such as
    /// the interface orientation of the guest.
    var onPropertiesChange: (() -> Void)? { get set }
    /// The display angle for the guest's interface orientation, as SimulatorKit
    /// applies it when Rotate Device Automatically is on.
    var guestInterfaceAngle: Double? { get }
    /// Creates the message for one event of `input`, so that a command can
    /// prepare all of its events before it sends any.
    func message(for input: HIDInput, _ state: HIDState) throws -> HIDMessage
    /// Sends a message. `completion`, when present, receives SimulatorKit's
    /// delivery result; a thrown error means the message was not sent.
    func send(_ message: HIDMessage, completion: (@MainActor (Error?) -> Void)?) throws
    /// Taps the integrated screen at `point`, in unit coordinates from the top-left corner of the screen in its own
    /// orientation, with the touch input that the display's own touches use. Returns once the tap is sent; the guest
    /// acts on it after that. Throws when the tap could not be sent, and for a display whose touches the app cannot send.
    func tap(at point: CGPoint) async throws
    /// Presses and releases `keys` in order on a keyboard that the guest reads with the US layout. Returns once the
    /// keys are sent; the guest acts on them after that. Throws when a key could not be sent, and for a display whose
    /// keys the app cannot send.
    func type(_ keys: [TypedKey]) async throws
    /// The frontmost application of the integrated screen with its accessibility elements, as
    /// `SimulatorDevice.frontmostAccessibilityElements()` reads them. Throws for a display that reads none.
    func frontmostAccessibilityElements() async throws -> SimulatorAccessibilityElement?
    /// The accessibility element at `point` of the integrated screen, in points from its top-left corner, as
    /// `SimulatorDevice.accessibilityElement(at:)` reads it. Throws for a display that reads none.
    func accessibilityElement(at point: CGPoint) async throws -> SimulatorAccessibilityElement?
    /// The application of a guest process with its accessibility elements, among them those that an alert or a sheet
    /// covers, as `SimulatorDevice.accessibilityElements(ofProcess:)` reads them. Throws for a display that reads none.
    func accessibilityElements(ofProcess processIdentifier: Int32) async throws -> SimulatorAccessibilityElement?
    /// Performs an action on one accessibility element of a guest process's application, as
    /// `SimulatorDevice.performAccessibilityAction(_:inProcess:on:)` does. Throws for a display that reads no
    /// accessibility elements.
    func performAccessibilityAction(
        _ action: SimulatorAccessibilityAction, inProcess processIdentifier: Int32,
        on choose: @escaping @Sendable ([SimulatorAccessibilityElement]) -> Int?
    ) async throws
    /// A connection to the device's Web Inspector service. Throws for a device that has none.
    func webInspector() async throws -> SimulatorWebInspector
    /// Builds a remote touch message held until its end phase, for `send(_:completion:)`.
    func message(for touch: TVRemoteTouch) throws -> HIDMessage
    /// Sends a watch gesture. `completion` receives SimulatorKit's delivery
    /// result; a thrown error means the gesture was not sent.
    func send(_ gesture: WatchGesture, completion: @escaping @MainActor (Error?) -> Void) throws
    /// Reads and flips the guest's appearance as one request.
    func toggleAppearance() async throws
    /// The device's own StandBy service, or nil when the guest presents StandBy for its notification.
    var standBy: (any DeviceStandBy)? { get }
    /// Posts a Darwin notification in the guest.
    func postNotification(_ name: String) async throws
    /// Sets a Darwin notification's state in the guest and posts it, as one request. Throws
    /// ``GuestNotificationNotPosted`` when the state changed and only the post failed.
    func sendNotificationState(_ name: String, to state: UInt64) async throws
    /// Reads a Darwin notification's state, then sets and posts what `change` makes of it, as one request. Throws
    /// ``GuestNotificationNotPosted`` when the state changed and only the post failed.
    func updateNotificationState(_ name: String, _ change: @escaping @Sendable (UInt64) -> UInt64) async throws
    /// Reads the guest's preferred text size, numbered as `SimulatorDevice` numbers it, and sets what `change` makes of
    /// it, if anything, as one request.
    func updateContentSizeCategory(_ change: @escaping @Sendable (Int) throws -> Int?) async throws
    /// Reads Increase Contrast's mode, 1 when it is off and 2 when it is on and 0 when unknown, and sets whether it is on
    /// as `change` decides, as one request.
    func updateIncreaseContrast(_ change: @escaping @Sendable (Int) throws -> Bool) async throws
    func triggerCloudSync() async throws
    /// The guest values that `notifications` and `debugOptions` name, read as one request. CoreSimulator drops the error
    /// of a debug option's read, so false can also mean that it failed.
    func guestState(notifications: [String], debugOptions: [CADebugOption]) async throws -> GuestStateReading
    /// The folder of the device's logs.
    func logDirectory() throws -> URL
    /// The file whose write makes the guest simulate a memory warning.
    func memoryWarningFile() throws -> URL
    /// Reads a Core Animation debug option, sets the opposite and reads it back, as one request.
    /// CoreSimulator drops the error of this change.
    func toggleCADebugOption(_ option: CADebugOption) async throws -> CADebugOptionChange
    // Returns recorded routes in CoreSimulator order. Location calls run serially off the main actor.
    func locationScenarios() async throws -> [LocationScenario]
    func clearSimulatedLocation() async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    /// Runs the route a `LocationScenario.name` names.
    func setLocationScenario(_ name: String) async throws
    // Changes the guest keyboard serially off the main actor.
    func setHardwareKeyboardConnected(_ connected: Bool) async throws
    /// Sets the language of the guest's keyboard, such as `en` or `ja`.
    func setKeyboardLanguage(_ language: String) async throws
    /// The change count of the Mac pasteboard that the display's pasteboard connections manage.
    var hostPasteboardChangeCount: Int { get }
    /// Connects to the device's pasteboard through the transport its route chose, waiting for that transport to become
    /// ready. A failure to reach the routed transport throws and falls back to nothing, and the next call tries again.
    /// `sync` orders device copies across devices; `events` receives the connection's callbacks.
    func connectPasteboard(sync: PasteboardSync?,
                           events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) async throws -> any SimulatorPasteboard
    /// Connects to the device's audio route port. `changed` runs on the main
    /// actor after each change the port reports, until it disconnects.
    func connectAudioRoutes(changed: @escaping @MainActor (AudioRouteChange) -> Void) async throws -> any SimulatorAudioRoutes
    /// Observes the existing or subsequently connected TVOut screen on the main actor.
    /// Each connection reports property changes through `changed` until disconnected.
    /// Releasing the token ends reports except queued callbacks; nil means no adapter.
    func registerForExternalScreen(
        changed: @escaping @MainActor () -> Void,
        found: @escaping @MainActor (Result<any SimulatorExternalScreen, any Error>) -> Void
    ) throws -> AnyObject?
    func setRotation(degrees: Double)
    func disconnect()
    /// Disconnects, then removes the native input services the display owns once they have sent the input they
    /// accepted. Every removal is attempted and their failures are thrown together, unless the device has shut down;
    /// the input owners keep what they could not remove, which the next call removes again.
    func stop() async throws
}

extension DeviceSessionDisplay {
    package var captureDisplayID: UInt32? { nil }
    package var standBy: (any DeviceStandBy)? { nil }
    /// A display that does not report its guest's startup has nothing to wait for.
    package func waitForGuestStartup() async throws {}
    package func connectAppDisplay(uniqueID: String) async throws -> any DeviceSessionDisplay {
        throw SimulatorError.unavailable("This display cannot connect to the app resizing screen.")
    }
    package func frontmostAccessibilityElements() async throws -> SimulatorAccessibilityElement? {
        throw SimulatorError.unavailable("This display reads no accessibility elements.")
    }
    package func accessibilityElement(at point: CGPoint) async throws -> SimulatorAccessibilityElement? {
        throw SimulatorError.unavailable("This display reads no accessibility elements.")
    }
    package func accessibilityElements(
        ofProcess processIdentifier: Int32
    ) async throws -> SimulatorAccessibilityElement? {
        throw SimulatorError.unavailable("This display reads no accessibility elements.")
    }
    package func performAccessibilityAction(
        _ action: SimulatorAccessibilityAction, inProcess processIdentifier: Int32,
        on choose: @escaping @Sendable ([SimulatorAccessibilityElement]) -> Int?
    ) async throws {
        throw SimulatorError.unavailable("This display reads no accessibility elements.")
    }
    package func webInspector() async throws -> SimulatorWebInspector {
        throw SimulatorError.unavailable("This display's device has no Web Inspector service.")
    }
    package func tap(at point: CGPoint) async throws {
        throw SimulatorError.unavailable("This display takes no taps from the app.")
    }
    package func type(_ keys: [TypedKey]) async throws {
        throw SimulatorError.unavailable("This display takes no typing from the app.")
    }
}

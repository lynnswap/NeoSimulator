import CoreGraphics
import NeoSimulatorDeviceIO
import NeoSimulatorKit

extension LoginStore {
    /// Signs in to what the login's app shows on `session`'s device, its own sign-in form or a web authentication
    /// session, with the login that `id` names as the keychain holds it now. Throws what kept the sign-in from
    /// finishing, such as a ``WebAuthenticationSignIn/Failure`` or a ``NativeFormSignIn/Failure``.
    ///
    /// One sign-in runs on a simulator at a time, whether the menu or the command-line tool asked for it: two would
    /// fill and submit the same form, and each would clear what the other filled in.
    ///
    /// - Parameter automated: Whether a caller other than the person at the Mac asked. Such a sign-in uses only a
    ///   login that allows it, as the keychain holds the login when the sign-in reads its password.
    package func signIn(with id: SavedLogin.ID, on session: DeviceSession, automated: Bool = false) async throws {
        let device = session.device.identifier
        guard signingIn.insert(device).inserted else {
            throw SignInRefusal("Another sign-in is running on this simulator.")
        }
        defer { signingIn.remove(device) }
        let (login, password) = try await credentials(for: id)
        guard !automated || login.allowsAutomation else {
            throw SignInRefusal("No login with this label allows automated use.")
        }
        try await WebAuthenticationSignIn(device: SessionSignInDevice(session), login: login, password: password).run()
    }
}

/// A device session as a sign-in uses it. It keeps one Web Inspector connection for the sign-in: the device's service
/// can end with its last connection, and then takes about ten seconds to answer the next.
@MainActor
private final class SessionSignInDevice: SignInDevice {
    private let session: DeviceSession
    private var inspector: SimulatorWebInspector?

    init(_ session: DeviceSession) { self.session = session }

    private func connectedInspector() async throws -> SimulatorWebInspector {
        if let inspector { return inspector }
        let inspector = try await session.display.webInspector()
        self.inspector = inspector
        return inspector
    }

    func frontmostApplication() async throws -> SimulatorAccessibilityElement? {
        try await session.display.frontmostAccessibilityElements()
    }

    func element(at point: CGPoint) async throws -> SimulatorAccessibilityElement? {
        try await session.display.accessibilityElement(at: point)
    }

    func pages() async throws -> [InspectablePage] { try await connectedInspector().pages() }

    func run(_ script: SignInScript, in page: InspectablePage) async throws -> SignInPageState {
        try await connectedInspector().evaluate(script.expression, in: page, as: SignInPageState.self)
    }

    func tap(at point: CGPoint) async throws { try await session.tap(at: point) }

    func application(ofProcess processIdentifier: Int32) async throws -> SimulatorAccessibilityElement? {
        try await session.display.accessibilityElements(ofProcess: processIdentifier)
    }

    func perform(
        _ action: SimulatorAccessibilityAction, inProcess processIdentifier: Int32,
        on choose: @escaping @Sendable ([SimulatorAccessibilityElement]) -> Int?
    ) async throws {
        try await session.display.performAccessibilityAction(action, inProcess: processIdentifier, on: choose)
    }
}

import CoreGraphics
import NeoSimulatorDeviceIO
import NeoSimulatorKit

extension LoginStore {
    /// Signs in to the web authentication session that `session`'s device shows, with the login that `id` names as
    /// the keychain holds it now. Throws what kept the sign-in from finishing, such as a
    /// ``WebAuthenticationSignIn/Failure``.
    package func signIn(with id: SavedLogin.ID, on session: DeviceSession) async throws {
        let (login, password) = try await credentials(for: id)
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

    func pages() async throws -> [InspectablePage] { try await connectedInspector().pages() }

    func run(_ script: SignInScript, in page: InspectablePage) async throws -> SignInPageState {
        try await connectedInspector().evaluate(script.expression, in: page, as: SignInPageState.self)
    }

    func tap(at point: CGPoint) async throws { try await session.tap(at: point) }
}

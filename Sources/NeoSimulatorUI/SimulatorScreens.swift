import AppKit
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters

/// One connected simulator screen that can move between embedded and window presentations. Its device, commands and
/// lifetime are its ``session``'s.
@MainActor
public final class SimulatorScreen {
    /// The open device this screen presents.
    public let session: SimulatorDeviceSession
    package let controller: DeviceWindowController

    /// The device snapshot taken when this screen was opened.
    public var device: SimulatorDeviceSnapshot { session.device }
    public var isClosed: Bool { session.isClosed }
    /// Called once after the screen ends. Closing a screen leaves its guest running.
    public var onEnd: ((SimulatorScreenEnd) -> Void)? {
        get { session.onEnd }
        set { session.onEnd = newValue }
    }

    fileprivate init(session: SimulatorDeviceSession, controller: DeviceWindowController) {
        self.session = session
        self.controller = controller
    }

    /// Moves this screen into a view controller, replacing its previous presentation.
    /// One simulator screen can be embedded in each window.
    public func embed(in viewController: NSViewController) throws {
        try session.checkOpen()
        try controller.validatePresentationMove()
        controller.embed(in: viewController)
    }

    /// Moves this screen into its own window and brings it forward.
    public func showWindow() throws {
        try session.checkOpen()
        try controller.validatePresentationMove()
        controller.showCompactWindow()
    }

    /// Removes the current presentation while keeping the connection available.
    public func detach() throws {
        try session.checkOpen()
        try controller.validatePresentationMove()
        controller.detachPresentation()
    }

    public func focusInput() {
        guard !isClosed else { return }
        controller.focusInput()
    }

    /// Releases this screen's resources without shutting down the guest.
    /// If cleanup fails after the screen closes, this throws and `isClosed` remains true.
    /// Call again, or invalidate the context, to retry the unfinished cleanup.
    public func close() async throws {
        try await session.close()
    }
}

/// Presents the devices of one ``SimulatorContext``.
///
/// Creating this loads the process's UI toolkit, so that a context which only reads and manages devices never does. It
/// fails when another application is displaying the simulators. A context takes one of these.
@MainActor
public final class SimulatorScreens {
    public let context: SimulatorContext
    private struct Presented { weak var screen: SimulatorScreen? }
    /// What keeps a screen is its session's own owner and whoever uses it, so this outlives neither.
    private var presented: [SimulatorDeviceIdentifier: Presented] = [:]

    public init(context: SimulatorContext) async throws {
        self.context = context
        try await mappingToSimulatorError {
            try await context.installPresentation(load: {
                _ = try await SimulatorPresentationRuntime.load(xcodeURL: context.xcodeURL)
            }, presenter: DeviceWindowPresenter(), conflicts: HostConflictMonitor())
        }
    }

    /// Attaches to an already running guest and presents it. Boot it through the context first when necessary. Reopening
    /// an attached device returns the same screen. Concurrent callers share the connection; canceling one caller only
    /// cancels that caller's wait.
    public func open(_ id: SimulatorDeviceIdentifier) async throws -> SimulatorScreen {
        try await mappingToSimulatorError { screen(of: try await context.openSession(id)) }
    }

    package func screen(for id: SimulatorDeviceIdentifier) -> SimulatorScreen? {
        context.session(for: id).map(screen(of:))
    }

    package var openScreens: [SimulatorScreen] { context.openSessions.map(screen(of:)) }

    private func screen(of session: SimulatorDeviceSession) -> SimulatorScreen {
        if let screen = presented[session.device.id]?.screen, screen.session === session { return screen }
        guard let controller = session.presentation as? DeviceWindowController else {
            preconditionFailure("A context's sessions are presented by its SimulatorScreens.")
        }
        let screen = SimulatorScreen(session: session, controller: controller)
        presented[session.device.id] = Presented(screen: screen)
        return screen
    }
}

/// An AppKit container that presents a simulator screen through its supported embedding path.
@MainActor
public final class SimulatorScreenViewController: NSViewController {
    public let screen: SimulatorScreen

    public init(screen: SimulatorScreen) throws {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
        try screen.embed(in: self)
    }

    public required init?(coder: NSCoder) { nil }

    public override func loadView() { view = NSView() }
}

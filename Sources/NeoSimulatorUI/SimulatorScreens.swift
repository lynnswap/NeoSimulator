import AppKit
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters

/// A connected simulator screen that moves between embedded and window presentations.
/// Its ``session`` provides the device, commands, and lifetime.
@MainActor
public final class SimulatorScreen {
    /// The open device this screen presents.
    public let session: SimulatorDeviceSession
    package let controller: DeviceWindowController

    /// The device snapshot taken when this screen was opened.
    public var device: SimulatorDeviceSnapshot { session.device }
    /// Whether the screen has ended. It becomes `true` before ``onEnd`` is called, and ``close()`` can throw after it does.
    public var isClosed: Bool { session.isClosed }
    /// Called once after the screen ends. Closing a screen leaves its guest running.
    ///
    /// This is the same closure as the ``session``'s, so setting one replaces the other.
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
    ///
    /// The screen fills the safe area of the view controller's view, which this loads if needed.
    ///
    /// - Parameter viewController: The view controller to present the screen in.
    /// - Throws: ``/NeoSimulatorKit/SimulatorError/operation(_:)`` if the screen has ended, or if its window is showing a
    ///   sheet or is in full screen.
    public func embed(in viewController: NSViewController) throws {
        try session.checkOpen()
        try controller.validatePresentationMove()
        controller.embed(in: viewController)
    }

    /// Moves this screen into its own window and brings it forward.
    ///
    /// - Throws: ``/NeoSimulatorKit/SimulatorError/operation(_:)`` if the screen has ended, or if its window is showing a
    ///   sheet or is in full screen.
    public func showWindow() throws {
        try session.checkOpen()
        try controller.validatePresentationMove()
        controller.showCompactWindow()
    }

    /// Removes the current presentation while keeping the connection available.
    ///
    /// Call ``embed(in:)`` or ``showWindow()`` to present the screen again.
    ///
    /// - Throws: ``/NeoSimulatorKit/SimulatorError/operation(_:)`` if the screen has ended, or if its window is showing a
    ///   sheet or is in full screen.
    public func detach() throws {
        try session.checkOpen()
        try controller.validatePresentationMove()
        controller.detachPresentation()
    }

    /// Directs keyboard input to the presented screen.
    ///
    /// This does nothing if the screen has ended, is not presented, or its device cannot accept commands now.
    public func focusInput() {
        guard !isClosed else { return }
        controller.focusInput()
    }

    /// Releases this screen's resources without shutting down the guest.
    /// If cleanup fails after the screen closes, this throws and `isClosed` remains true.
    /// Call again, or invalidate the context, to retry the unfinished cleanup.
    ///
    /// - Throws: ``/NeoSimulatorKit/SimulatorError`` if cleanup fails, or `CancellationError` if the cleanup is cancelled.
    public func close() async throws {
        try await session.close()
    }
}

/// Presents the devices of one ``/NeoSimulatorKit/SimulatorContext``.
///
/// Creation loads the process's UI toolkit and fails if a competing app is displaying
/// simulators. Each context accepts one presenter.
@MainActor
public final class SimulatorScreens {
    /// The context whose devices this presents. This object retains it.
    public let context: SimulatorContext
    private struct Presented { weak var screen: SimulatorScreen? }
    /// Weak references; sessions and callers own the screens.
    private var presented: [SimulatorDeviceIdentifier: Presented] = [:]

    /// Creates the presenter of `context`.
    ///
    /// A failed creation leaves the context without a presenter, so you can create another.
    ///
    /// - Parameter context: The context to present.
    /// - Throws: ``/NeoSimulatorKit/SimulatorError/conflict(_:)`` if Apple's Simulator or Device Hub is running,
    ///   ``/NeoSimulatorKit/SimulatorError/operation(_:)`` if the context has stopped or already has a presenter,
    ///   another ``/NeoSimulatorKit/SimulatorError`` if the UI toolkit cannot load, or `CancellationError` if the caller
    ///   is cancelled.
    public init(context: SimulatorContext) async throws {
        self.context = context
        try await install(presenter: DeviceWindowPresenter())
    }

    package init(context: SimulatorContext, makeWindow: @escaping (AvailableDevice) -> DeviceWindow?) async throws {
        self.context = context
        try await install(presenter: DeviceWindowPresenter(makeWindow: makeWindow))
    }

    private func install(presenter: DeviceWindowPresenter) async throws {
        let context = context
        try await mappingToSimulatorError {
            try await context.installPresentation(load: {
                _ = try await SimulatorPresentationRuntime.load(xcodeURL: context.xcodeURL)
                }, presenter: presenter, conflicts: HostConflictMonitor())
        }
    }

    /// Attaches to a running guest. Use the context to boot it first if needed.
    /// Reopening a device whose screen you retain returns the same screen. Concurrent callers share the connection;
    /// cancelling one caller ends only its wait.
    ///
    /// - Parameter id: The simulator to open.
    /// - Returns: The simulator's screen, which is not presented until you call ``SimulatorScreen/embed(in:)`` or
    ///   ``SimulatorScreen/showWindow()``.
    /// - Throws: ``/NeoSimulatorKit/SimulatorError`` if the context has stopped, the simulator is not running or is no
    ///   longer available, another app is displaying simulators, or the screen closes before it finishes opening, or
    ///   `CancellationError` if the caller is cancelled.
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
    /// The screen that this controller presents. The controller retains it.
    public let screen: SimulatorScreen

    /// Creates a controller and embeds `screen` in it.
    ///
    /// - Parameter screen: The screen to present.
    /// - Throws: ``/NeoSimulatorKit/SimulatorError/operation(_:)`` if the screen has ended, or if its window is showing a
    ///   sheet or is in full screen.
    public init(screen: SimulatorScreen) throws {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
        try screen.embed(in: self)
    }

    /// Returns `nil`, because this controller cannot be created from an archive.
    public required init?(coder: NSCoder) { nil }

    /// Creates the empty view that holds the screen.
    public override func loadView() { view = NSView() }
}

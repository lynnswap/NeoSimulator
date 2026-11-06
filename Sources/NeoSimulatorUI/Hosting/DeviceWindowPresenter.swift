import AppKit
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters

/// Where the next new device window goes, which a presenter's windows share.
@MainActor
package final class WindowCascade {
    package var next = NSPoint.zero
    package init() {}
}

/// Draws a host's devices in AppKit windows, over the displays that `SimulatorScreenRouter` connects.
@MainActor
package final class DeviceWindowPresenter: DevicePresenter {
    private let displays: SimulatorDisplaySet
    private let router: SimulatorScreenRouter
    private let touchPressure = TouchPressure()
    private let tvRemote = TVRemoteController()
    private let cascade = WindowCascade()
    package let captureOwner = UUID()

    package init() {
        let displays = SimulatorDisplaySet()
        self.displays = displays
        router = SimulatorScreenRouter(displays: displays)
    }

    package func connectDisplay(_ request: DeviceConnectionRequest) async throws -> ConnectedDeviceDisplay {
        try await router.connect(request)
    }

    package func makePresentation(of session: DeviceSession, offersLifetimeChoice: Bool,
                                  events: DevicePresentationEvents) throws -> any DevicePresentation {
        var onShutDown: ((DeviceWindowController) -> Void)?
        if let shutDown = events.onShutDown { onShutDown = { shutDown($0) } }
        return try DeviceWindowController(
            session: session, displays: displays, touchPressure: touchPressure, tvRemote: tvRemote, cascade: cascade,
            offersLifetimeChoice: offersLifetimeChoice, captureOwner: captureOwner,
            reportDetachedCapture: events.reportDetachedCapture,
            onClose: { events.onClose($0, $1) }, onRestart: { events.onRestart($0, $1) }, onShutDown: onShutDown)
    }

    package func beginFinishingCaptures() { CaptureThumbnail.beginFinishing(owner: captureOwner) }

    package func finishCaptures(before deadline: ContinuousClock.Instant) async -> [any Error] {
        await CaptureThumbnail.finishAll(owner: captureOwner, before: deadline)
    }

    package func acknowledgeCaptureFailures() { CaptureThumbnail.acknowledgeFailures(owner: captureOwner) }

    package func openLog(_ log: URL) async throws {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            throw SimulatorError.unavailable("Console is not installed.")
        }
        _ = try await NSWorkspace.shared.open([log], withApplicationAt: console,
                                              configuration: NSWorkspace.OpenConfiguration())
    }

    package func hostKeyboardLanguage() -> String? { HostKeyboard.language() }
}

extension SimulatorScreenHost {
    /// The window of `identifier`'s device, when a `DeviceWindowPresenter` presents it.
    package func controller(for identifier: SimulatorDeviceIdentifier) -> DeviceWindowController? {
        presentation(for: identifier) as? DeviceWindowController
    }

    /// The windows of the host's devices.
    package var windowControllers: [DeviceWindowController] {
        presentations.compactMap { $0 as? DeviceWindowController }
    }
}

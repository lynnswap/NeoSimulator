import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit

package struct RendererOwnerIdentity: Equatable, Sendable {
    package let processIdentifier: Int32
    package let launchDate: Date

    package init(processIdentifier: Int32, launchDate: Date) {
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
    }

    @MainActor package static func current() throws -> Self {
        let application = NSRunningApplication.current
        guard let launchDate = application.launchDate else {
            throw HostOperationError.unavailable("renderer-owner", "The manager's launch identity could not be read.")
        }
        return Self(processIdentifier: application.processIdentifier, launchDate: launchDate)
    }

    @MainActor
    package func isRunning(applicationURL: URL) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated, application.launchDate == launchDate,
              let url = application.bundleURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath()
            == applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

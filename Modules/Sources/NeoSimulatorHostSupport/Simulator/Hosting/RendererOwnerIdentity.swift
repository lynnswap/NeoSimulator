import NeoSimulatorKit
@_spi(NeoSimulator) import XcodeSimulatorHost
import AppKit
import Darwin
import Synchronization

package struct RendererOwnerIdentity: Equatable {
    package let processIdentifier: Int32
    package let launchDate: Date

    package init(processIdentifier: Int32, launchDate: Date) {
        self.processIdentifier = processIdentifier
        self.launchDate = launchDate
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

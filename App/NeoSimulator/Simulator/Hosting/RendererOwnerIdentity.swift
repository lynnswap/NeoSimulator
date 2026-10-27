import AppKit
import Darwin
import Synchronization
@_spi(NeoSimulator) import XcodeSimulatorHost

struct RendererOwnerIdentity: Equatable {
    let processIdentifier: Int32
    let launchDate: Date

    @MainActor
    func isRunning(applicationURL: URL) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated, application.launchDate == launchDate,
              let url = application.bundleURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath()
            == applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

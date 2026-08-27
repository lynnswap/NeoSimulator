import AppKit
import Foundation

struct RunningApplication: Equatable {
    let processIdentifier: pid_t
    let bundleURL: URL?
}

@MainActor
struct WorkspaceClient {
    var runningXcodes: () -> [RunningApplication]
    var openApplication: (URL) async throws -> URL

    static let live = WorkspaceClient(
        runningXcodes: {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: ToolConstants.xcodeBundleIdentifier
            ).map {
                RunningApplication(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL
                )
            }
        },
        openApplication: { applicationURL in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false

            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            guard let openedURL = application.bundleURL else {
                throw CLIError.io(
                    "simulator-launch",
                    "LaunchServices opened Simulator without a bundle URL"
                )
            }

            let expected = applicationURL.resolvingSymlinksInPath().standardizedFileURL
            let observed = openedURL.resolvingSymlinksInPath().standardizedFileURL
            guard observed == expected else {
                throw CLIError.io(
                    "simulator-substitution",
                    "requested \(expected.path), but LaunchServices opened \(observed.path)"
                )
            }
            return observed
        }
    )
}

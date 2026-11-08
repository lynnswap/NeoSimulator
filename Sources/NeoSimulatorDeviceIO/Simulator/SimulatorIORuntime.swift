import ABIBridge
import Foundation

/// One Xcode's CoreSimulator context: its device sets, creation catalog and audio ports. Preparing it loads CoreSimulator
/// and chooses no UI toolkit.
@MainActor
package final class SimulatorIORuntime {
    private static var preparations: [URL: Task<SimulatorIORuntime, any Error>] = [:]
    /// The Xcode that owns this device context and its command-line tools.
    package let xcodeURL: URL
    package let coreSimulator: CoreSimulatorInterface
    package let audio: SimulatorAudioInterface

    /// Joins a context's in-flight preparation while its native values stay on the main actor.
    package static func load(xcodeURL: URL) async throws -> SimulatorIORuntime {
        try Task.checkCancellation()
        let source = xcodeURL.resolvingSymlinksInPath()
        if let preparation = preparations[source] {
            let runtime = try await CoreDeviceRuntime.preparedValue(of: preparation)
            try Task.checkCancellation()
            return runtime
        }
        let preparation = Task {
            defer { preparations[source] = nil }
            return try await SimulatorIORuntime(xcodeURL: source)
        }
        preparations[source] = preparation
        let runtime = try await CoreDeviceRuntime.preparedValue(of: preparation)
        try Task.checkCancellation()
        return runtime
    }

    private init(xcodeURL: URL) async throws {
        self.xcodeURL = xcodeURL
        coreSimulator = try await .load()
        audio = try await ABIRuntime.shared.prepare { try await SimulatorAudioInterface(runtime: $0) }
    }

    package static func creationCatalog(xcodeURL: URL) async throws -> SimulatorCatalog.Snapshot {
        try await SimulatorDeviceSet.load(xcodeURL: xcodeURL).readCatalog()
    }

    /// The owner of the default device set, or of the set at `path`.
    package func openDeviceSet(at path: String? = nil, listing: [String]? = nil) -> SimulatorDeviceSet {
        SimulatorDeviceSet.shared(
            interface: coreSimulator,
            developerDirectory: xcodeURL.appendingPathComponent("Contents/Developer").path, path: path, listing: listing)
    }
}

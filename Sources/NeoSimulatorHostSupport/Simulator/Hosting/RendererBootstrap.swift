import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters
import NeoSimulatorUI

/// What the renderer process starts with, which composes the layers that its entry point does not see.
@MainActor
package final class RendererBootstrap {
    private let conflicts = HostConflictMonitor()

    package init() {}

    /// Chooses the Xcode whose UI toolkit this process loads.
    package static func selectToolkit(xcodeURL: URL) throws {
        try CoreDeviceRuntime.configureUIFrameworks(xcodeURL: xcodeURL)
    }

    /// The encoded catalog of what can be created with `xcodeURL`'s runtimes, without anything that draws.
    package static func creationCatalog(xcodeURL: URL) async throws -> Data {
        try JSONEncoder().encode(try await SimulatorIORuntime.creationCatalog(xcodeURL: xcodeURL))
    }

    /// Loads what a display needs from `xcodeURL`, which throws if it cannot be used. With `includingNativeBindings`, this
    /// returns the encoded report of the optional native bindings.
    package static func validateRuntime(xcodeURL: URL, includingNativeBindings: Bool) async throws -> Data? {
        _ = try await SimulatorPresentationRuntime.load(xcodeURL: xcodeURL)
        guard includingNativeBindings else { return nil }
        return try JSONEncoder().encode(await NativeRuntimeValidationReport.prepareOptionalBindings())
    }

    /// Throws ``SimulatorError/conflict(_:)`` while another application displays the simulators.
    package func checkForConflict() throws { try conflicts.check() }

    /// Loads the runtime and makes the application that hosts it.
    package func makeApplication(xcodeURL: URL, isManaged: Bool, owner: RendererOwnerIdentity?,
                                 headless: Bool) async throws -> HostApplication {
        let runtime = try await SimulatorPresentationRuntime.load(xcodeURL: xcodeURL)
        SimulatorPreferences.migrateStandalonePreferences()
        HostPreferences.configure(defaults: .standard,
            deviceSettingsDefaults: UserDefaults(suiteName: "dev.lynnswap.NeoSimulator"))
        return try HostApplication(runtime: runtime.io, conflicts: conflicts, isManaged: isManaged,
                                   owner: owner, headless: headless)
    }
}

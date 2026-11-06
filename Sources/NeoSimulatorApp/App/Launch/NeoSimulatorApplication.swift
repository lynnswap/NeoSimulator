import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorUI

public enum NeoSimulatorApplication {
    @MainActor public static func main(makeLicenses: @escaping @MainActor () -> NSViewController) {
        let app = NSApplication.shared
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            app.run()
            return
        }
#endif
        app.setActivationPolicy(.regular)
        do {
            try CoreDeviceRuntime.configureUIFrameworks(xcodeURL: UIFrameworkSettings.selection(in: .standard))
        } catch {
            NSAlert(presenting: error).runModal()
            return
        }
        // A launch URL can create the menus before launch finishes, and their
        // pasteboard synchronization reads its saved choice or default when created.
        SimulatorPreferences.migrateStandalonePreferences()
        HostPreferences.configure(
            defaults: UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard,
            deviceSettingsDefaults: .standard)
        HostPreferences.registerDefaults()
        let delegate = AppDelegate(makeLicenses: makeLicenses, splitViewAutosaveName: "NeoSimulatorDevices")
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

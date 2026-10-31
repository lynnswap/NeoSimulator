import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

@main
enum NeoSimulatorApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
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
        HostPreferences.registerDefaults()
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

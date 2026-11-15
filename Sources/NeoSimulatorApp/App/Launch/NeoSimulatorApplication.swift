import AppKit
import ArgumentParser
import NeoSimulatorDeviceIO
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorUI
import NeoSimulatorManager

/// Starts the NeoSimulator manager. Only the app's Xcode target calls this; it is not a supported API.
@_spi(AppBootstrap) public enum NeoSimulatorApplication {
    @MainActor public static func main(makeLicenses: @escaping @MainActor () -> NSViewController) {
#if DEBUG
        // Started with one of the command-line tool's commands, the executable asks the NeoSimulator that is running
        // and exits. Other arguments, such as those that Xcode and AppKit pass, start the app.
        if let command = CommandLine.arguments.dropFirst().first, NeoSimulatorCommand.launchArguments.contains(command) {
            NeoSimulatorCommand.main()
        }
#endif
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

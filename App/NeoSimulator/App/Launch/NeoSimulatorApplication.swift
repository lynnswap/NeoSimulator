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
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

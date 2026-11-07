import AppKit
@_spi(AppBootstrap) import NeoSimulatorApp

@main
enum NeoSimulatorMain {
    @MainActor static func main() {
        NeoSimulatorApplication.main(makeLicenses: { LicensesSettingsViewController() })
    }
}

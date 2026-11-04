import AppKit

@main
enum NeoSimulatorMain {
    @MainActor static func main() {
        NeoSimulatorApplication.main(makeLicenses: { LicensesSettingsViewController() })
    }
}

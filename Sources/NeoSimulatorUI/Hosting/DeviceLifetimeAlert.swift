import AppKit
import NeoSimulatorKit

extension DeviceLifetimeChoice {
    /// Return chooses the default action.
    @MainActor package static func alert(quitting: Bool, keepsRunningByDefault: Bool) -> NSAlert {
        let alert = NSAlert()
        if quitting {
            alert.messageText = "Do you want to shut down the simulated devices?"
            alert.informativeText = "You may choose to shut down all running simulated devices or keep them running."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Do you want to shutdown the simulated device?"
            alert.informativeText = "When closing a window, you can either shut down the device or keep it running."
        }
        alert.addButton(withTitle: quitting ? "Shut Down" : "Shut down")
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title =
            quitting ? "Remember as the default quit action." : "Remember as the default close action."
        if keepsRunningByDefault {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        return alert
    }

    /// The choice an alert response names, saved as the default under `key`
    /// when the suppression box is checked. Cancel names none.
    @MainActor package static func choice(for response: NSApplication.ModalResponse, of alert: NSAlert,
                       rememberingAs key: String) -> Self? {
        let choice: Self
        switch response {
        case .alertFirstButtonReturn: choice = .shutDown
        case .alertSecondButtonReturn: choice = .keepRunning
        default: return nil
        }
        if alert.suppressionButton?.state == .on { HostPreferences.defaults.set(choice == .keepRunning, forKey: key) }
        return choice
    }
}

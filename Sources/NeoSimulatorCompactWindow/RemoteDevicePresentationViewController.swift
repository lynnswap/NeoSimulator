import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit

@MainActor
package final class RemoteDevicePresentationViewController: NSViewController {
    package weak var owner: RemoteDeviceWindowController?

    package override func viewDidLayout() {
        super.viewDidLayout()
        owner?.layoutScreen()
    }

    package override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let owner {
            switch action {
            case #selector(RemoteDeviceWindowController.saveScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.recordScreen(_:)),
                 #selector(RemoteDeviceWindowController.recordScreenTo(_:)),
                 #selector(RemoteDeviceWindowController.stopScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.saveScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.chooseCaptureSource(_:)):
                return owner
            default: break
            }
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
}

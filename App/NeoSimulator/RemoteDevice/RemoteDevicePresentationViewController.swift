import AppKit

@MainActor
final class RemoteDevicePresentationViewController: NSViewController {
    weak var owner: RemoteDeviceWindowController?

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let owner {
            switch action {
            case #selector(RemoteDeviceWindowController.saveScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenshot(_:)),
                 #selector(RemoteDeviceWindowController.recordScreen(_:)),
                 #selector(RemoteDeviceWindowController.recordScreenTo(_:)),
                 #selector(RemoteDeviceWindowController.stopScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.saveScreenRecording(_:)),
                 #selector(RemoteDeviceWindowController.discardScreenRecording(_:)):
                return owner
            default: break
            }
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
}

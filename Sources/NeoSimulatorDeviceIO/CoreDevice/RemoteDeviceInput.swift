import Foundation

package enum RemoteDeviceInputKind: Hashable, Sendable {
    case keyboard, pointer, digitizer, button
    /// Trackpad scrolling and pinches over the touchscreen.
    case gesture
}

package enum RemoteDeviceButtonState: String, Sendable { case down, up }

package enum RemoteDevicePointerPhase: String, Sendable { case down, up, dragged }

package enum RemoteDeviceTouchPhase: String, Sendable { case began, moved, ended }

package enum RemoteDeviceTouchEdge: String, Sendable { case none, top, left, right, bottom }

package enum RemoteDeviceOrientation: String, Sendable {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown
}

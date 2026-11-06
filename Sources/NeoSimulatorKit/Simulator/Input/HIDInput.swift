import Foundation

/// A hardware button, by its Indigo HID button number.
package enum DeviceButton: UInt32 {
    case home = 0, lock = 1, applePay = 500, softwareKeyboard = 1008, siri = 1010
    /// The watch side button.
    case side = 3000
    /// The Action button on devices with the `com.apple.hid.sting` feature.
    case actionSting = 3001
    /// The Action button on devices with the `com.apple.hid.staccato` feature.
    case actionStaccato = 3002

    /// The HID usage page and usage that CoreDevice's and DeviceKit's buttons send for this button.
    package var nativeUsage: (page: Int, usage: Int) {
        switch self {
        case .home: (0x0c, 0x40)
        case .lock: (0x0c, 0x30)
        // AL Digital Wallet.
        case .applePay: (0x0c, 0x1ba)
        // Eject, which DeviceKit's Toggle Software Keyboard sends.
        case .softwareKeyboard: (0x0c, 0xb8)
        // Voice Command.
        case .siri: (0x0c, 0xcf)
        case .side: (0x0c, 0x95)
        // User Defined 1 on Apple's vendor keyboard page, which DeviceKit's watchOS Action button sends.
        case .actionSting: (0xff01, 0x200)
        // A telephony-page usage, which DeviceKit's iOS Action button sends.
        case .actionStaccato: (0x0b, 0x2d)
        }
    }
}

/// A button of the Apple TV Remote, by the Indigo HID button number that
/// Simulator.app's remote sends.
package enum TVRemoteButton: UInt32 {
    case select = 0x190, menu = 0x191, tv = 0x192, playPause = 0x194
    case volumeUp = 0x195, volumeDown = 0x196, siri = 0x3f2
}

/// A touch on the Apple TV Remote's touch surface.
package struct TVRemoteTouch: Equatable {
    package enum Phase { case began, moved, ended }

    package var phase: Phase
    /// Where the touch is, from 0 to 1 from the surface's top-left corner.
    package var point: CGPoint
}

/// Watch-gesture values accepted by IndigoHIDMessageForWatchGesture.
package enum WatchGesture: UInt32 {
    case doubleTap = 0, wristFlick = 1
}

/// An input Simulator.app sends as a down event and an up event.
package enum HIDInput: Hashable {
    case button(DeviceButton)
    /// A HID usage, such as a key on the consumer usage page.
    case usage(page: UInt32, usage: UInt32)
    /// A button of the Apple TV Remote.
    case tvRemote(TVRemoteButton)
    /// Held remote touch, built by `SimulatorDisplay.message(for:)` with its coordinates.
    case tvRemoteTouch

    package static let screenshot = HIDInput.usage(page: 0x0c, usage: 0x65)
    package static let volumeUp = HIDInput.usage(page: 0x0c, usage: 0xe9)
    package static let volumeDown = HIDInput.usage(page: 0x0c, usage: 0xea)

    /// The HID usage that a device's native button service takes for this input. Nil for the Apple TV Remote's inputs,
    /// which go to the remote's own targets.
    package var nativeButtonUsage: (page: Int, usage: Int)? {
        switch self {
        case .button(let button): button.nativeUsage
        case .usage(let page, let usage): (Int(page), Int(usage))
        case .tvRemote, .tvRemoteTouch: nil
        }
    }
}

package enum HIDState: UInt32 { case down = 1, up = 2 }

/// A Core Animation debug option of the guest, numbered as
/// `SimDevice setCADebugOption:enabled:` numbers it.
public enum CADebugOption: UInt32, CaseIterable, Sendable {
    case colorCopiedImages = 1
    case colorBlendedLayers = 2
    case colorMisalignedImages = 14
    case colorOffscreenRendered = 17

    /// The Debug menu's title for the option.
    package var title: String {
        switch self {
        case .colorCopiedImages: "Color Copied Images"
        case .colorBlendedLayers: "Color Blended Layers"
        case .colorMisalignedImages: "Color Misaligned Images"
        case .colorOffscreenRendered: "Color Off-screen Rendered"
        }
    }
}

/// An Indigo HID message for one event. Sending transfers it to SimulatorKit;
/// a message that is not sent is freed.
package final class HIDMessage {
    package let input: HIDInput
    package let state: HIDState
    private var pointer: OpaquePointer?

    package init(input: HIDInput, state: HIDState, pointer: OpaquePointer) {
        self.input = input
        self.state = state
        self.pointer = pointer
    }

    package func take() -> OpaquePointer {
        guard let pointer else { preconditionFailure("A HID message is sent once.") }
        self.pointer = nil
        return pointer
    }

    deinit { free(UnsafeMutableRawPointer(pointer)) }
}

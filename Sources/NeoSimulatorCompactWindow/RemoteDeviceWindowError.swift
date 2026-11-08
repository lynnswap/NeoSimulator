import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation

package enum RemoteDeviceWindowError: LocalizedError {
    case cleanup([String])
    case unavailable(String)
    package var errorDescription: String? {
        switch self {
        case .cleanup(let failures): failures.joined(separator: "\n")
        case .unavailable(let message): message
        }
    }
}

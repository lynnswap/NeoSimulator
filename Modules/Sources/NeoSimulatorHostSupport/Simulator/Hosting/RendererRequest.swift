import NeoSimulatorKit
@_spi(NeoSimulator) import XcodeSimulatorHost
import AppKit
import Darwin
import Synchronization

package enum RendererRequest: Equatable {
    case openDevice(SimulatorDeviceIdentifier)
    case quit(asks: Bool)
    case activate
    case showBrowser

    package init(url: URL) throws {
        guard url.scheme == "neosimulator-renderer", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SimulatorError.invalidArguments("Unsupported renderer URL: \(url.absoluteString)")
        }
        switch components.host {
        case "activate": self = .activate
        case "show-browser": self = .showBrowser
        case "open-device":
            guard let value = components.queryItems?.first(where: { $0.name == "udid" })?.value,
                  let identifier = UUID(uuidString: value) else {
                throw SimulatorError.invalidArguments("The renderer URL requires a device UDID.")
            }
            self = .openDevice(SimulatorDeviceIdentifier(identifier.uuidString, deviceSetPath: components.queryItems?.first(where: { $0.name == "deviceSetPath" })?.value))
        case "quit":
            self = .quit(asks: components.queryItems?.first(where: { $0.name == "ask" })?.value == "true")
        default:
            throw SimulatorError.invalidArguments("Unsupported renderer URL: \(url.absoluteString)")
        }
    }
}

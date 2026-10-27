import AppKit
import Darwin
import Synchronization
@_spi(NeoSimulator) import XcodeSimulatorHost

struct HostLaunchOptions {
    let xcodeURL: URL
    let validatesRuntime: Bool
    let readsCreationCatalog: Bool
    let startupResultURL: URL?
    let deviceIdentifier: String?
    let deviceSetPath: String?
    let isManaged: Bool
    let isHeadless: Bool
    let owner: RendererOwnerIdentity?

    init(arguments: [String]) throws {
        var xcodePath: String?
        var resultPath: String?
        var device: String?
        var deviceSet: String?
        var validate = false
        var creationCatalog = false
        var managed = false
        var headless = false
        var ownerPID: Int32?
        var ownerLaunchDate: Date?
        var index = 0
        func invalid() -> HostError {
            .invalidArguments("Expected [--managed --owner-pid PID --owner-launch-date SECONDS] [--validate-runtime] [--startup-result /absolute/path] [--device UDID] [--device-set /absolute/path] --xcode /absolute/path/to/Xcode.app")
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--managed":
                guard !managed else { throw invalid() }
                managed = true
            case "--headless":
                guard !headless else { throw invalid() }
                headless = true
            case "--owner-pid":
                index += 1
                guard index < arguments.count, ownerPID == nil,
                      let pid = Int32(arguments[index]), pid > 0 else { throw invalid() }
                ownerPID = pid
            case "--owner-launch-date":
                index += 1
                guard index < arguments.count, ownerLaunchDate == nil,
                      let seconds = Double(arguments[index]), seconds.isFinite else { throw invalid() }
                ownerLaunchDate = Date(timeIntervalSinceReferenceDate: seconds)
            case "--validate-runtime":
                guard !validate else { throw invalid() }
                validate = true
            case "--creation-catalog":
                guard !creationCatalog else { throw invalid() }
                creationCatalog = true
            case "--device":
                index += 1
                guard index < arguments.count, device == nil,
                      let identifier = UUID(uuidString: arguments[index]) else { throw invalid() }
                device = identifier.uuidString
            case "--xcode", "--startup-result", "--device-set":
                let option = arguments[index]
                index += 1
                guard index < arguments.count, (arguments[index] as NSString).isAbsolutePath else { throw invalid() }
                if option == "--device-set" {
                    guard deviceSet == nil else { throw invalid() }
                    deviceSet = arguments[index]
                } else if option == "--xcode" {
                    guard xcodePath == nil else { throw invalid() }
                    xcodePath = arguments[index]
                } else {
                    guard resultPath == nil else { throw invalid() }
                    resultPath = arguments[index]
                }
            default: throw invalid()
            }
            index += 1
        }
        guard let xcodePath, !(validate && resultPath != nil),
              !headless || managed,
              managed ? (ownerPID != nil && ownerLaunchDate != nil) : (ownerPID == nil && ownerLaunchDate == nil)
        else { throw invalid() }
        xcodeURL = URL(fileURLWithPath: xcodePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        validatesRuntime = validate
        readsCreationCatalog = creationCatalog
        startupResultURL = resultPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        deviceIdentifier = device
        deviceSetPath = deviceSet
        isManaged = managed
        isHeadless = headless
        owner = ownerPID.flatMap { pid in ownerLaunchDate.map { RendererOwnerIdentity(processIdentifier: pid, launchDate: $0) } }
    }

    func validateInstallation() throws {
        guard Bundle(url: xcodeURL)?.bundleIdentifier == "com.apple.dt.Xcode" else {
            throw HostError.unavailable("\(xcodeURL.path) is not an Xcode application")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: xcodeURL.appendingPathComponent("Contents/Developer").path,
                                             isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HostError.unavailable("\(xcodeURL.path) has no Contents/Developer directory")
        }
    }
}

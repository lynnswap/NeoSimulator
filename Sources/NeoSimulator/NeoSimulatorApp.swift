import AppKit

struct HostLaunchOptions {
    let xcodeURL: URL
    let validatesRuntime: Bool
    let startupResultURL: URL?
    let deviceIdentifier: String?
    let isManaged: Bool

    init(arguments: [String]) throws {
        var xcodePath: String?
        var resultPath: String?
        var device: String?
        var validate = false
        var managed = false
        var index = 0
        func invalid() -> HostError {
            .invalidArguments("Expected [--managed] [--validate-runtime] [--startup-result /absolute/path] [--device UDID] --xcode /absolute/path/to/Xcode.app")
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--managed":
                guard !managed else { throw invalid() }
                managed = true
            case "--validate-runtime":
                guard !validate else { throw invalid() }
                validate = true
            case "--device":
                index += 1
                guard index < arguments.count, device == nil,
                      let identifier = UUID(uuidString: arguments[index]) else { throw invalid() }
                device = identifier.uuidString
            case "--xcode", "--startup-result":
                let option = arguments[index]
                index += 1
                guard index < arguments.count, (arguments[index] as NSString).isAbsolutePath else { throw invalid() }
                if option == "--xcode" {
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
        guard let xcodePath, !(validate && resultPath != nil) else { throw invalid() }
        xcodeURL = URL(fileURLWithPath: xcodePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        validatesRuntime = validate
        startupResultURL = resultPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        deviceIdentifier = device
        isManaged = managed
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

enum RendererRequest: Equatable {
    case openDevice(String)
    case quit(asks: Bool)
    case activate
    case showBrowser

    init(url: URL) throws {
        guard url.scheme == "neosimulator-renderer", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HostError.invalidArguments("Unsupported renderer URL: \(url.absoluteString)")
        }
        switch components.host {
        case "activate": self = .activate
        case "show-browser": self = .showBrowser
        case "open-device":
            guard let value = components.queryItems?.first(where: { $0.name == "udid" })?.value,
                  let identifier = UUID(uuidString: value) else {
                throw HostError.invalidArguments("The renderer URL requires a device UDID.")
            }
            self = .openDevice(identifier.uuidString)
        case "quit":
            self = .quit(asks: components.queryItems?.first(where: { $0.name == "ask" })?.value == "true")
        default:
            throw HostError.invalidArguments("Unsupported renderer URL: \(url.absoluteString)")
        }
    }
}

#if !NEOSIMULATOR_TESTS
@main
enum NeoSimulatorApp {
    @MainActor
    static func main() {
#if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            NSApplication.shared.run()
            return
        }
#endif
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("usage: NeoSimulatorRenderer [--managed] [--validate-runtime] [--startup-result /absolute/path] [--device UDID] --xcode /absolute/path/to/Xcode.app")
            return
        }
        do {
            let options = try HostLaunchOptions(arguments: arguments)
            try options.validateInstallation()
            if options.validatesRuntime {
                _ = try SimulatorRuntime(xcodeURL: options.xcodeURL)
                return
            }
            let conflicts = HostConflictMonitor()
            try conflicts.check()
            let runtime = try SimulatorRuntime(xcodeURL: options.xcodeURL)
            HostPreferences.migrateStandalonePreferences()
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let controller = try HostApplication(runtime: runtime, conflicts: conflicts, isManaged: options.isManaged)
            app.delegate = controller
            app.finishLaunching()
            try controller.start(initialDeviceIdentifier: options.deviceIdentifier)
            do { try conflicts.check() }
            catch {
                controller.shutdown()
                throw error
            }
            if let result = options.startupResultURL {
                do { try Data("ready\n".utf8).write(to: result, options: .atomic) }
                catch {
                    controller.shutdown()
                    hostLog("Could not write startup result: \(error.localizedDescription)")
                    exit(EX_CANTCREAT)
                }
            }
            app.activate()
            withExtendedLifetime(controller) { app.run() }
        } catch {
            hostLog(error.localizedDescription)
            if case HostError.invalidArguments = error { exit(EX_USAGE) }
            if case HostError.conflict = error { exit(EX_TEMPFAIL) }
            exit(EX_UNAVAILABLE)
        }
    }
}
#endif

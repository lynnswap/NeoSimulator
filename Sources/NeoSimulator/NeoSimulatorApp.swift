import AppKit

struct HostLaunchOptions {
    let xcodeURL: URL
    let validatesRuntime: Bool
    let startupResultURL: URL?

    init(arguments: [String]) throws {
        var xcodePath: String?
        var resultPath: String?
        var validate = false
        var index = 0
        func invalid() -> HostError {
            .invalidArguments("Expected [--validate-runtime] [--startup-result /absolute/path] --xcode /absolute/path/to/Xcode.app")
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--validate-runtime":
                guard !validate else { throw invalid() }
                validate = true
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
            print("usage: NeoSimulator [--validate-runtime] [--startup-result /absolute/path] --xcode /absolute/path/to/Xcode.app")
            return
        }
        do {
            let options = try HostLaunchOptions(arguments: arguments)
            try options.validateInstallation()
            if !options.validatesRuntime, let name = HostApplication.conflictingHostName {
                throw HostError.conflict("\(name) is running; close it before opening NeoSimulator")
            }
            let runtime = try SimulatorRuntime(xcodeURL: options.xcodeURL)
            if options.validatesRuntime { return }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let controller = try HostApplication(runtime: runtime)
            app.delegate = controller
            app.finishLaunching()
            try controller.start()
            if let name = HostApplication.conflictingHostName {
                controller.shutdown()
                throw HostError.conflict("\(name) launched before startup completed")
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

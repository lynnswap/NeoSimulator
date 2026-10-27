import AppKit
import Darwin
import Synchronization
@_spi(NeoSimulator) import XcodeSimulatorHost

@main
enum NeoSimulatorApp {
    @MainActor private static var controller: HostApplication?
    @MainActor private static var ownerMonitor: RendererOwnerMonitor?

    /// LaunchServices can deliver requests while native bindings are being prepared.
    @MainActor
    private final class StartupDelegate: NSObject, NSApplicationDelegate {
        private enum Event {
            case open([URL])
            case reopen
        }
        private var events: [Event] = []

        func application(_ application: NSApplication, open urls: [URL]) {
            events.append(.open(urls))
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            events.append(.reopen)
            return true
        }

        func replay(to controller: HostApplication, application: NSApplication) {
            for event in events {
                switch event {
                case .open(let urls): controller.application(application, open: urls)
                case .reopen: _ = controller.applicationShouldHandleReopen(application, hasVisibleWindows: false)
                }
            }
            events.removeAll()
        }
    }

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
            print("usage: NeoSimulatorRenderer [--managed --owner-pid PID --owner-launch-date SECONDS] [--validate-runtime] [--startup-result /absolute/path] [--device UDID] [--device-set /absolute/path] --xcode /absolute/path/to/Xcode.app")
            return
        }
        if arguments == ["--relaunch-manager"] {
            Task { await ManagerRelaunch.runHelper() }
            dispatchMain()
        }
        let options: HostLaunchOptions
        do {
            options = try HostLaunchOptions(arguments: arguments)
        } catch { fail(error) }
        do {
            try options.validateInstallation()
            try CoreDeviceRuntime.configureUIFrameworks(xcodeURL: options.xcodeURL)
        }
        catch { fail(error, resultURL: options.startupResultURL) }
        if options.readsCreationCatalog || options.validatesRuntime {
            Task { await runHelper(options: options) }
            dispatchMain()
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let startup = StartupDelegate()
        application.delegate = startup
        Task { await start(options: options, application: application, startup: startup) }
        application.run()
        ownerMonitor?.stop()
        controller = nil
    }

    @MainActor
    private static func runHelper(options: HostLaunchOptions) async -> Never {
        do {
            if options.readsCreationCatalog {
                let catalog = try await SimulatorRuntime.creationCatalog(xcodeURL: options.xcodeURL)
                let data = try JSONEncoder().encode(SimulatorCatalog.Snapshot(catalog: catalog))
                try FileHandle.standardOutput.write(contentsOf: data)
            } else {
                _ = try await SimulatorRuntime.load(xcodeURL: options.xcodeURL)
            }
            exit(EX_OK)
        } catch { fail(error) }
    }

    @MainActor
    private static func start(options: HostLaunchOptions, application: NSApplication, startup: StartupDelegate) async {
        do {
            // LaunchServices owns the Unix parent. The explicit manager identity owns this renderer.
            if let owner = options.owner {
                let managerURL = Bundle.main.bundleURL.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                guard owner.isRunning(applicationURL: managerURL) else { exit(EX_OK) }
                ownerMonitor = RendererOwnerMonitor(processIdentifier: owner.processIdentifier,
                                                     cleanup: HostApplication.requestTerminationAfterOwnerExit)
                guard owner.isRunning(applicationURL: managerURL) else { ownerMonitor?.stop(); exit(EX_OK) }
            } else { ownerMonitor = nil }
            let conflicts = HostConflictMonitor()
            try conflicts.check()
            let runtime = try await SimulatorRuntime.load(xcodeURL: options.xcodeURL)
            HostPreferences.migrateStandalonePreferences()
            let controller = try HostApplication(runtime: runtime, conflicts: conflicts, isManaged: options.isManaged,
                                                 owner: options.owner, headless: options.isHeadless)
            Self.controller = controller
            application.delegate = controller
            try controller.start(initialDeviceIdentifier: options.deviceIdentifier, initialDeviceSetPath: options.deviceSetPath)
            do { try conflicts.check() }
            catch {
                controller.shutdown()
                throw error
            }
            if let result = options.startupResultURL {
                do { try JSONEncoder().encode(RendererStartupResult.ready).write(to: result, options: .atomic) }
                catch {
                    controller.shutdown()
                    hostLog("Could not write startup result: \(error.localizedDescription)")
                    exit(EX_CANTCREAT)
                }
            }
            application.activate()
            startup.replay(to: controller, application: application)
        } catch { fail(error, resultURL: options.startupResultURL) }
    }

    private static func fail(_ error: any Error, resultURL: URL? = nil) -> Never {
        if let resultURL {
            do {
                let result = RendererStartupResult.failed(message: error.localizedDescription,
                    recoverySuggestion: (error as? any LocalizedError)?.recoverySuggestion)
                try JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
            } catch { hostLog("Could not write startup failure: \(error.localizedDescription)") }
        }
        hostLog(error.localizedDescription)
        if case HostError.invalidArguments = error { exit(EX_USAGE) }
        if case HostError.conflict = error { exit(EX_TEMPFAIL) }
        exit(EX_UNAVAILABLE)
    }
}

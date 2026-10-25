import AppKit
import Darwin
import Synchronization


struct RendererOwnerIdentity: Equatable {
    let processIdentifier: Int32
    let launchDate: Date

    @MainActor
    func isRunning(applicationURL: URL) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated, application.launchDate == launchDate,
              let url = application.bundleURL else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath()
            == applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// The deadline runs independently of AppKit, including while native display code blocks its run loop.
final class RendererOwnerMonitor: Sendable {
    typealias Cancellation = @Sendable () -> Void
    typealias ObserveExit = @Sendable (Int32, @escaping @Sendable () -> Void) -> Cancellation
    typealias ScheduleDeadline = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Cancellation
    private struct State {
        var ownerExited = false
        var stopped = false
        var cancelObservation: Cancellation?
        var cancelDeadline: Cancellation?
    }
    private let state = Mutex(State())
    private let schedule: ScheduleDeadline
    private let forceExit: @Sendable () -> Void
    private let cleanup: @Sendable () -> Void

    init(processIdentifier: Int32, cleanup: @escaping @Sendable () -> Void,
         observeExit: ObserveExit = RendererOwnerMonitor.observeProcess,
         scheduleDeadline: @escaping ScheduleDeadline = RendererOwnerMonitor.scheduleDeadline,
         forceExit: @escaping @Sendable () -> Void = { _exit(EX_TEMPFAIL) }) {
        self.schedule = scheduleDeadline
        self.forceExit = forceExit
        self.cleanup = cleanup
        let cancel = observeExit(processIdentifier) { [weak self] in self?.ownerDidExit() }
        let stopped = state.withLock { value in
            if value.stopped { return true }
            value.cancelObservation = cancel
            return false
        }
        if stopped { cancel() }
    }

    private func ownerDidExit() {
        let beginsCleanup = state.withLock { value in
            guard !value.stopped, !value.ownerExited else { return false }
            value.ownerExited = true
            return true
        }
        guard beginsCleanup else { return }
        let cancel = schedule(60) { [weak self] in
            guard let self, self.state.withLock({ !$0.stopped && $0.ownerExited }) else { return }
            self.forceExit()
        }
        let stopped = state.withLock { value in
            if value.stopped { return true }
            value.cancelDeadline = cancel
            return false
        }
        if stopped { cancel(); return }
        cleanup()
    }

    func stop() {
        let cancellations = state.withLock { value -> [Cancellation] in
            value.stopped = true
            let result = [value.cancelObservation, value.cancelDeadline].compactMap { $0 }
            value.cancelObservation = nil
            value.cancelDeadline = nil
            return result
        }
        for cancel in cancellations { cancel() }
    }

    deinit { stop() }

    private static func observeProcess(_ pid: Int32, exited: @escaping @Sendable () -> Void) -> Cancellation {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: exited)
        source.activate()
        return { source.cancel() }
    }

    private static func scheduleDeadline(_ seconds: TimeInterval, expired: @escaping @Sendable () -> Void) -> Cancellation {
        let source = DispatchSource.makeTimerSource(queue: .global())
        source.schedule(deadline: .now() + seconds)
        source.setEventHandler(handler: expired)
        source.activate()
        return { source.cancel() }
    }
}

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

enum RendererRequest: Equatable {
    case openDevice(SimulatorDeviceIdentifier)
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
            self = .openDevice(SimulatorDeviceIdentifier(identifier.uuidString, deviceSetPath: components.queryItems?.first(where: { $0.name == "deviceSetPath" })?.value))
        case "quit":
            self = .quit(asks: components.queryItems?.first(where: { $0.name == "ask" })?.value == "true")
        default:
            throw HostError.invalidArguments("Unsupported renderer URL: \(url.absoluteString)")
        }
    }
}

#if !NEOSIMULATOR_TESTS && !NEOSIMULATOR_MANAGER
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
        let options: HostLaunchOptions
        do {
            options = try HostLaunchOptions(arguments: arguments)
            try options.validateInstallation()
        } catch { fail(error) }
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
                do { try Data("ready\n".utf8).write(to: result, options: .atomic) }
                catch {
                    controller.shutdown()
                    hostLog("Could not write startup result: \(error.localizedDescription)")
                    exit(EX_CANTCREAT)
                }
            }
            application.activate()
            startup.replay(to: controller, application: application)
        } catch { fail(error) }
    }

    private static func fail(_ error: any Error) -> Never {
        hostLog(error.localizedDescription)
        if case HostError.invalidArguments = error { exit(EX_USAGE) }
        if case HostError.conflict = error { exit(EX_TEMPFAIL) }
        exit(EX_UNAVAILABLE)
    }
}
#endif

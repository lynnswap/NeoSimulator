import AppKit
import NeoSimulatorKit

@main
enum MinimalSimulatorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var context: SimulatorContext?
    private var screen: SimulatorScreen?
    private var window: NSWindow?
    private var guestToShutDown: SimulatorDeviceIdentifier?
    private var termination: Task<Void, Never>?
    private var asynchronousFailures: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await start() }
            catch {
                print("Failed: \(error.localizedDescription)")
                do { try await finish() } catch { print("Cleanup failed: \(error.localizedDescription)") }
                exit(1)
            }
        }
    }

    private func start() async throws {
        let context = try await SimulatorContext.load()
        self.context = context
        context.onError = { [weak self] in self?.asynchronousFailures.append($0.localizedDescription) }
        let devices = try await context.devices()
        let arguments = CommandLine.arguments
        guard let option = arguments.firstIndex(of: "--device"), option + 1 < arguments.count else {
            for device in devices {
                print("\(device.id.identifier)\t\(device.name)\t\(device.runtimeName)\t\(device.state)")
            }
            try await context.invalidate()
            exit(0)
        }
        let id = SimulatorDeviceIdentifier(arguments[option + 1])
        let wasShutDown = devices.first { $0.id == id }?.state == .shutDown
        if wasShutDown { guestToShutDown = id }
        _ = try await context.boot(id)
        let screen: SimulatorScreen
        if arguments.contains("--exercise") {
            let first = Task.immediate { try await context.openScreen(id) }
            let cancelled = Task.immediate { try await context.openScreen(id) }
            cancelled.cancel()
            let second = Task.immediate { try await context.openScreen(id) }
            screen = try await first.value
            guard try await second.value === screen else {
                throw SimulatorError.operation("Concurrent opens created different screens.")
            }
            do { _ = try await cancelled.value } catch is CancellationError {} catch { throw error }
        } else {
            screen = try await context.openScreen(id)
        }
        self.screen = screen
        screen.onEnd = { print("Screen ended: \($0)") }
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit MinimalSimulatorApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        if arguments.contains("--embed") {
            let content = try SimulatorScreenViewController(screen: screen)
            let window = NSWindow(contentViewController: content)
            window.setContentSize(NSSize(width: 500, height: 800))
            window.title = screen.device.name
            window.makeKeyAndOrderFront(nil)
            self.window = window
        } else {
            try screen.showWindow()
        }
        NSApp.activate()
        print("Opened \(screen.device.name)")
        if arguments.contains("--exercise-external-shutdown") {
            guard guestToShutDown == id else {
                throw SimulatorError.operation("The external shutdown exercise requires a shut-down simulator.")
            }
            var ended: (SimulatorScreenEnd, Task<SimulatorDeviceState?, any Error>)?
            screen.onEnd = { reason in
                ended = (reason, Task.immediate {
                    try await context.devices().first { $0.id == id }?.state
                })
            }
            let developerDirectory = context.xcodeURL.appending(path: "Contents/Developer").path
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "shutdown", id.identifier]
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = developerDirectory
            process.environment = environment
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = {
                    if $0.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: SimulatorError.operation("The external simctl shutdown failed.")) }
                }
                do { try process.run() }
                catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while ended == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard let (reason, observed) = ended else {
                throw SimulatorError.operation("The external shutdown did not end the screen.")
            }
            let state = try await observed.value
            guard reason == .deviceStopping && (state == .shuttingDown || state == .shutDown)
                    || reason == .deviceStopped && state == .shutDown else {
                throw SimulatorError.operation("The screen's end reason did not match the guest state.")
            }
            guestToShutDown = nil
            try await finish()
            print("External shutdown exercise completed: \(reason)")
            exit(0)
        }
        if arguments.contains("--exercise-callback") {
            guard guestToShutDown == id else {
                throw SimulatorError.operation("The callback exercise requires a shut-down simulator.")
            }
            var shutdown: Task<Void, any Error>?
            screen.onEnd = { reason in
                if reason == .closed { shutdown = Task.immediate { try await context.shutDown(id) } }
            }
            try await screen.close()
            guard let shutdown else { throw SimulatorError.operation("The close callback did not run.") }
            try await shutdown.value
            guard try await context.devices().contains(where: { $0.id == id && $0.state == .shutDown }) else {
                throw SimulatorError.operation("A shutdown requested by the close callback left the guest running.")
            }
            guestToShutDown = nil
            try await finish()
            print("Callback exercise completed")
            exit(0)
        }
        if arguments.contains("--exercise") {
            guard try await context.openScreen(id) === screen else {
                throw SimulatorError.operation("Reopening a screen created a second connection.")
            }
            try await Task.sleep(for: .seconds(2))
            try screen.detach()
            try screen.showWindow()
            var end: SimulatorScreenEnd?
            screen.onEnd = { end = $0; print("Screen ended: \($0)") }
            try screen.press(.home) { [weak self] in self?.asynchronousFailures.append($0.localizedDescription) }
            let closing = Task.immediate { try await screen.close() }
            let secondClose = Task.immediate { try await screen.close() }
            let reopening = Task.immediate { try await context.openScreen(id) }
            try await closing.value
            try await secondClose.value
            guard screen.isClosed, end == .closed,
                  try await context.devices().contains(where: { $0.id == id && $0.state == .booted }) else {
                throw SimulatorError.operation("Closing the screen did not preserve the running guest.")
            }
            self.screen = try await reopening.value
            guard self.screen !== screen else {
                throw SimulatorError.operation("Reopening during close returned the closing screen.")
            }
            try self.screen?.showWindow()
            try await Task.sleep(for: .seconds(1))
            if guestToShutDown == id {
                end = nil
                self.screen?.onEnd = { end = $0 }
                let closing = Task.immediate { try await self.screen?.close() }
                let stopping = Task.immediate { try await context.shutDown(id) }
                let secondStop = Task.immediate { try await context.shutDown(id) }
                try await closing.value
                try await stopping.value
                try await secondStop.value
                guestToShutDown = nil
                guard self.screen?.isClosed == true, end == .deviceStopped else {
                    throw SimulatorError.operation("Shutting down did not end the screen.")
                }
            }
            try await finish()
            try await context.invalidate()
            if !asynchronousFailures.isEmpty {
                throw SimulatorError.operation(asynchronousFailures.joined(separator: "\n"))
            }
            print("Exercise completed")
            exit(0)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard termination == nil else { return .terminateLater }
        termination = Task {
            do { try await finish() } catch { print("Cleanup failed: \(error.localizedDescription)") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func finish() async throws {
        guard let context else { return }
        var failures: [String] = []
        do { try await screen?.close() } catch { failures.append(error.localizedDescription) }
        if let id = guestToShutDown {
            do { try await context.shutDown(id) } catch { failures.append(error.localizedDescription) }
            guestToShutDown = nil
        }
        do { try await context.invalidate() } catch { failures.append(error.localizedDescription) }
        window?.close()
        if !failures.isEmpty { throw SimulatorError.operation(failures.joined(separator: "\n")) }
    }
}

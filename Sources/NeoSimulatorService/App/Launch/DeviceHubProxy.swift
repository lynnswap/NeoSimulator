import AppKit
import Carbon
import CoreFoundation
import Darwin
import NeoSimulatorHostSupport
import NeoSimulatorKit

/// Receives Xcode's display requests without loading Device Hub or owning any simulator.
@MainActor
final class DeviceHubProxy: NSObject, NSApplicationDelegate {
    private let options: HostLaunchOptions
    private var previousApplication: NSRunningApplication?
    private var activationObserver: (any NSObjectProtocol)?
    private var ownerMonitor: RendererOwnerMonitor?

    init(options: HostLaunchOptions) { self.options = options }

    func run() throws {
        try register()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = self
        let events = NSAppleEventManager.shared()
        events.setEventHandler(
            self, andSelector: #selector(receiveURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        application.run()
        ownerMonitor?.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func register() throws {
        typealias CheckIn = @convention(c) (Int32, CFDictionary) -> Unmanaged<CFDictionary>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW) else {
            throw SimulatorError.unavailable("LaunchServices could not be loaded for the simulator display bridge.")
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_LSApplicationCheckIn"), let executable = Bundle.main.executableURL else {
            throw SimulatorError.unavailable("LaunchServices does not support the simulator display bridge.")
        }
        // Xcode targets its bundled Device Hub by path, even when application substitution is disabled.
        // Register this windowless process before AppKit checks in the renderer's normal identity.
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.apple.dt.Devices",
            "CFBundleName": "NeoSimulator Display Bridge",
            "CFBundleExecutable": executable.lastPathComponent,
            "LSBundlePath": options.xcodeURL.appendingPathComponent("Contents/Applications/DeviceHub.app").path,
            "LSExecutablePath": executable.path,
            "ApplicationType": "UIElement",
            "LSUIElement": true,
        ]
        let checkIn = unsafeBitCast(symbol, to: CheckIn.self)
        guard checkIn(-2, info as CFDictionary) != nil else {
            throw SimulatorError.unavailable("The simulator display bridge could not register with LaunchServices.")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let owner = options.owner else {
                throw SimulatorError.invalidArguments("A display bridge requires a manager.")
            }
            let managerURL = Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard owner.isRunning(applicationURL: managerURL) else { exit(EX_OK) }
            ownerMonitor = RendererOwnerMonitor(processIdentifier: owner.processIdentifier, cleanup: { _exit(EX_OK) })
            guard owner.isRunning(applicationURL: managerURL) else { exit(EX_OK) }
            previousApplication = NSWorkspace.shared.frontmostApplication
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let other = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    other.processIdentifier != ProcessInfo.processInfo.processIdentifier
                else { return }
                MainActor.assumeIsolated { self?.previousApplication = other }
            }
            if let result = options.startupResultURL {
                try JSONEncoder().encode(RendererStartupResult.ready).write(to: result, options: .atomic)
            }
        } catch {
            if let result = options.startupResultURL {
                do {
                    try JSONEncoder().encode(
                        RendererStartupResult.failed(
                            message: error.localizedDescription,
                            recoverySuggestion: (error as? any LocalizedError)?.recoverySuggestion)
                    ).write(to: result, options: .atomic)
                } catch { hostLog("Could not write display bridge startup failure: \(error.localizedDescription)") }
            }
            hostLog(error.localizedDescription)
            exit(EX_UNAVAILABLE)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { returnFocus() }

    private func returnFocus() {
        NSApp.setActivationPolicy(.accessory)
        guard NSRunningApplication.current.isActive, let previousApplication,
            previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            previousApplication.bundleIdentifier != "com.apple.loginwindow"
        else { return }
        NSApp.yieldActivation(to: previousApplication)
        _ = previousApplication.activate(from: .current, options: [])
    }

    @objc private func receiveURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        returnFocus()
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URLComponents(string: value), url.scheme == "devices"
        else { return }
        if url.host == "device", url.path == "/open",
            let id = url.queryItems?.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: id)
        {
            send("open-device", device: id)
        } else {
            openDeviceHub()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDeviceHub()
        return false
    }

    private func openDeviceHub() {
        send("open-device-hub")
    }

    private func send(_ action: String, device: UUID? = nil) {
        guard let owner = options.owner else { return }
        var info = ["pid": String(ProcessInfo.processInfo.processIdentifier), "action": action]
        if let device { info["device"] = device.uuidString }
        DistributedNotificationCenter.default().postNotificationName(
            DeviceHubCompanions.requestNotification,
            object: DeviceHubCompanions.token(for: owner), userInfo: info, deliverImmediately: true)
    }
}

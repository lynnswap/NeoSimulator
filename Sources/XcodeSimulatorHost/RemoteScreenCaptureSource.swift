import AVFoundation
import CoreMediaIO

/// A Mac screen-capture source for a USB-connected device.
///
/// macOS does not reveal which CoreDevice device a source belongs to, so a person
/// chooses each device's source. The source's capture identity stays internal.
@_spi(NeoSimulator)
public struct RemoteScreenCaptureSource: Hashable, Sendable {
    public let name: String
    let uniqueID: String
}

/// The device has no chosen capture source that is currently connected.
struct RemoteScreenCaptureSourceError: LocalizedError {
    enum Reason { case unchosen, disconnected }
    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .unchosen: "Choose this device’s screen source."
        case .disconnected: "This device’s screen isn’t available."
        }
    }

    var recoverySuggestion: String? {
        switch reason {
        case .unchosen: "macOS lists the screens of devices connected with a cable without saying which device each one shows."
        case .disconnected: "NeoSimulator shows the screen of a device connected to this Mac with a cable. Connect the device and try again, or choose its screen source."
        }
    }
}

/// Lists screen-capture sources and keeps the source chosen for each CoreDevice identifier.
@MainActor
protocol RemoteScreenCaptureSourceCatalog: AnyObject {
    func sources() async throws -> [RemoteScreenCaptureSource]
    func chosenSource(for deviceIdentifier: String) -> RemoteScreenCaptureSource?
    func choose(_ source: RemoteScreenCaptureSource, for deviceIdentifier: String)
    /// Waits briefly for a source that reappears after its device reconnects.
    func waitUntilConnected(_ source: RemoteScreenCaptureSource) async throws
}

/// Discovers screen-capture sources through AVFoundation and stores choices in the app's defaults.
@MainActor
final class ScreenCaptureSourceCatalog: RemoteScreenCaptureSourceCatalog {
    static let shared = ScreenCaptureSourceCatalog(defaults: .standard)
    static let preferenceKey = "RemoteScreenCaptureSources"

    private let defaults: UserDefaults
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var observation: NSKeyValueObservation?
    private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func sources() async throws -> [RemoteScreenCaptureSource] {
        let discovery = try discoverySession()
        // Sources are published shortly after the process opts in to screen-capture devices.
        await waitForDevices(timeout: .seconds(2)) { !discovery.devices.isEmpty }
        try Task.checkCancellation()
        return discovery.devices.map { RemoteScreenCaptureSource(name: $0.localizedName, uniqueID: $0.uniqueID) }
    }

    func chosenSource(for deviceIdentifier: String) -> RemoteScreenCaptureSource? {
        guard let entry = defaults.dictionary(forKey: Self.preferenceKey)?[deviceIdentifier] as? [String: String],
              let uniqueID = entry["uniqueID"], let name = entry["name"] else { return nil }
        return RemoteScreenCaptureSource(name: name, uniqueID: uniqueID)
    }

    func choose(_ source: RemoteScreenCaptureSource, for deviceIdentifier: String) {
        // One source shows one device, so another device's earlier choice of it no longer applies.
        var entries = (defaults.dictionary(forKey: Self.preferenceKey) ?? [:]).filter {
            ($0.value as? [String: String])?["uniqueID"] != source.uniqueID
        }
        entries[deviceIdentifier] = ["uniqueID": source.uniqueID, "name": source.name]
        defaults.set(entries, forKey: Self.preferenceKey)
    }

    func waitUntilConnected(_ source: RemoteScreenCaptureSource) async throws {
        let discovery = try discoverySession()
        let isConnected = { discovery.devices.contains { $0.uniqueID == source.uniqueID } }
        await waitForDevices(timeout: .seconds(5), until: isConnected)
        try Task.checkCancellation()
        guard isConnected() else {
            throw RemoteScreenCaptureSourceError(reason: .disconnected)
        }
    }

    private func discoverySession() throws -> AVCaptureDevice.DiscoverySession {
        if let discovery { return discovery }
        try Self.allowScreenCaptureDevices()
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        observation = session.observe(\.devices, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.devicesChanged() }
        }
        discovery = session
        return session
    }

    /// CoreMediaIO hides screen-capture devices until the process opts in. The setting
    /// applies only to this process and remains on while any screen may use it.
    private static func allowScreenCaptureDevices() throws {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &allow)
        guard status == kCMIOHardwareNoError else {
            throw CLIError.unavailable("screen-capture-devices", "macOS did not make device screen-capture sources available (CoreMediaIO status \(status)).")
        }
    }

    private func waitForDevices(timeout: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), !Task.isCancelled, ContinuousClock.now < deadline {
            await nextChange(before: deadline)
        }
    }

    private func nextChange(before deadline: ContinuousClock.Instant) async {
        let identifier = UUID()
        let timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.resumeChangeWaiter(identifier)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { changeWaiters[identifier] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeChangeWaiter(identifier) }
        }
    }

    private func resumeChangeWaiter(_ identifier: UUID) {
        changeWaiters.removeValue(forKey: identifier)?.resume()
    }

    private func devicesChanged() {
        let waiters = changeWaiters.values
        changeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

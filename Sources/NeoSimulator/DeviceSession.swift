import AppKit
import Observation

/// Device properties Simulator.app uses to show, hide, or enable commands.
struct DeviceCapabilities {
    /// `SimDeviceType.productFamilyID`.
    enum Family: Int { case iPhone = 1, iPad = 2, tv = 3, watch = 4, vision = 7 }

    var family: Family?
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    var runtimeVersion: UInt32
    /// `SimDevice supportsFeature:`, which combines device-type and runtime support.
    var supportsFeature: (String) -> Bool

    var isPhoneOrPad: Bool { family == .iPhone || family == .iPad }

    static let displayRotation = "com.apple.CoreSimulator.display.rotation"
}

/// One connected simulator: its display and input, its device tools, and every
/// operation that changes the device. Window controllers present a session and
/// report its failures; they do not run device work themselves.
@MainActor @Observable
final class DeviceSession {
    let device: AvailableDevice
    let capabilities: DeviceCapabilities
    @ObservationIgnored let display: any SimulatorDisplay
    @ObservationIgnored let tools: DeviceTools
    @ObservationIgnored private let recordings: RecordingStore
    @ObservationIgnored private let makeRecordingProcess: (URL) -> Process
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var isDisconnected = false
    /// A tool operation or a modal step that leads to one is in progress.
    private(set) var isBusy = false
    private(set) var isConnected = true
    private(set) var recording: VideoRecording?

    /// - Parameter recordingProcess: Creates the recording process for a
    ///   destination. Defaults to the device's direct `simctl` recorder.
    init(device: AvailableDevice, capabilities: DeviceCapabilities, display: any SimulatorDisplay,
         tools: DeviceTools, recordings: RecordingStore = RecordingStore(),
         recordingProcess: ((URL) -> Process)? = nil) {
        self.device = device
        self.capabilities = capabilities
        self.display = display
        self.tools = tools
        self.recordings = recordings
        makeRecordingProcess = recordingProcess ?? tools.recordingProcess(to:)
    }

    var canPerformCommands: Bool { isConnected && display.isBooted }
    var canPerformToolOperation: Bool { canPerformCommands && !isBusy }

    // MARK: Immediate device input

    func press(_ button: DeviceButton) throws {
        guard canPerformCommands else { return }
        try display.press(button)
    }

    func shake() throws {
        guard canPerformCommands else { return }
        try display.shake()
    }

    func toggleAppearance() throws {
        guard canPerformCommands else { return }
        try display.toggleAppearance()
    }

    // MARK: Device tool operations

    /// Holds the single device-operation slot for a modal step, such as a save
    /// panel, that precedes a tool operation. Returns false when it is taken.
    func reserve() -> Bool {
        guard canPerformToolOperation else { return false }
        isBusy = true
        return true
    }

    func release() {
        guard operation == nil else { return }
        isBusy = false
    }

    /// Runs one device tool operation at a time. The caller must hold no
    /// reservation. Errors other than cancellation are passed to `failure`.
    func run(_ body: @escaping @MainActor () async throws -> Void,
             failure: @escaping @MainActor (Error) -> Void) {
        guard canPerformToolOperation else { return }
        isBusy = true
        operation = Task { [weak self] in
            defer {
                if let self {
                    self.operation = nil
                    self.isBusy = false
                    self.isConnected = self.isConnected && self.display.isBooted
                }
            }
            do { try await body() }
            catch is CancellationError {}
            catch { failure(error) }
        }
    }

    /// Reads the device orientation and returns the display angle in degrees.
    func readOrientation() async throws -> Double {
        let angle = try await tools.orientation()
        try Task.checkCancellation()
        display.setRotation(degrees: angle)
        return angle
    }

    func rotate(left: Bool) async throws {
        let angle = try await tools.rotate(left: left)
        try Task.checkCancellation()
        display.setRotation(degrees: angle)
    }

    func saveScreenshot(to destination: URL) async throws {
        try await CaptureFile.write(to: destination, extension: "png") { temporary in
            try await tools.screenshot(to: temporary)
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                throw HostError.operation("The screenshot tool did not produce a PNG file")
            }
        }
    }

    func startRecording(to destination: URL) throws {
        guard canPerformCommands, recording == nil else { return }
        recording = try recordings.start(to: destination, process: makeRecordingProcess) { [weak self] in
            self?.recording = nil
        }
    }

    func stopRecording() { recording?.stop() }

    func importFiles(_ urls: [URL]) async throws {
        try await SimulatorFileImport.perform(urls) { url, kind in
            switch kind {
            case .application: try await tools.installApplication(at: url)
            case .media: try await tools.importMedia(at: url)
            }
        }
    }

    func openURL(_ url: URL) async throws { try await tools.openURL(url) }

    func shutDown() async throws {
        isConnected = false
        try await tools.shutdown()
    }

    // MARK: Lifetime

    func disconnect() {
        guard !isDisconnected else { return }
        isDisconnected = true
        isConnected = false
        operation?.cancel()
        tools.cancel()
        recording?.stop()
        display.disconnect()
    }

    isolated deinit { disconnect() }
}

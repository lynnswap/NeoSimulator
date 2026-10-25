import ABIBridge
import AppKit

@MainActor
final class ScreenSharingDeviceTransport: NSObject, RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let input: CoreDeviceScreenInput
    private let url: URL
    private let view: NSView
    private let options: AnyObject
    private let connect: NativeObjCMethod<Void, NSOrderedSet, NSOrderedSet?, AnyObject>
    private let close: NativeObjCMethod<Void>
    private let connected: NativeObjCMethod<Bool>
    private let disconnected: NativeObjCMethod<Bool>
    private let copyImage: NativeObjCMethod<Unmanaged<CGImage>?>
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var observing = false
    private var stopped = false
    private var requested = false
    private var stopping: Task<Void, any Error>?
    private let capabilityObservation: RemoteScreenInputCapabilityObservation
    var inputCapabilities: Set<RemoteDeviceInputKind> { capabilityObservation.capabilities }
    var nativeInputView: NSView? { view }
    var canCaptureScreenshot: Bool { !stopped }
    private(set) var canRecordScreen = false

    init(remote: CoreDeviceRemoteScreenDevice, url: URL, contentView: NSView) throws {
        try CoreDeviceRemoteScreenDevice.load("/System/Library/PrivateFrameworks/ScreenSharing.framework/ScreenSharing")
        guard let viewClass = NSClassFromString("SSSessionView") as? NSView.Type,
              let optionsClass = NSClassFromString("SSConnectionOptions") else {
            throw CLIError.unavailable("screen-sharing-runtime", "Screen Sharing is unavailable with this version of macOS.")
        }
        self.url = url
        self.remote = remote
        let input = CoreDeviceScreenInput(remote: remote)
        self.input = input
        capabilityObservation = RemoteScreenInputCapabilityObservation(source: try CoreDeviceInputCapabilitySource(remote: remote),
            read: { try input.capabilities() }, invalidateInputs: { input.discardInputs(for: $0) })
        view = viewClass.init(frame: contentView.bounds)
        view.autoresizingMask = [.width, .height]
        let runtime = remote.runtime
        let defaults = try runtime.resolveAndWait(.objc(.method("defaultOptions", as: (() -> AnyObject).self)), on: optionsClass, classMethod: true)
        options = try unsafe defaults.unsafeInvoke(on: optionsClass)
        let share = try runtime.resolveAndWait(.objc(.method("setShouldSharePasteboard:", as: ((Bool) -> Void).self)), on: Swift.type(of: options))
        try unsafe share.unsafeInvoke(on: options, false)
        for selector in ["setShouldSharePasteboard:", "setShouldAllowSendPasteboard:"] {
            let disable = try runtime.resolveAndWait(.objc(.method(selector, as: ((Bool) -> Void).self)), on: viewClass)
            try unsafe disable.unsafeInvoke(on: view, false)
        }
        connect = try runtime.resolveAndWait(.objc(.method("connectToURLs:withPreferredCredentials:options:",
            as: ((NSOrderedSet, NSOrderedSet?, AnyObject) -> Void).self)), on: viewClass)
        close = try runtime.resolveAndWait(.objc(.method("closeSession", as: (() -> Void).self)), on: viewClass)
        connected = try runtime.resolveAndWait(.objc(.method("isConnected", as: (() -> Bool).self)), on: viewClass)
        disconnected = try runtime.resolveAndWait(.objc(.method("isDisconnected", as: (() -> Bool).self)), on: viewClass)
        copyImage = try runtime.resolveAndWait(.objc(.method("copyCGImageFromRemoteScreen", as: (() -> Unmanaged<CGImage>?).self)), on: viewClass)
        super.init()
        contentView.addSubview(view)
    }

    isolated deinit {
        removeObservers()
        do { try unsafe close.unsafeInvoke(on: view) }
        catch { NSLog("NeoSimulator Screen Sharing cleanup failed: %@", String(describing: error)) }
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        guard !stopped else { throw CancellationError() }
        self.events = events
        try capabilityObservation.start(update: { [weak self] removed in
            self?.events?(removed.isEmpty ? .inputGeometryChanged : .inputCapabilitiesLost(removed))
        }, failure: { [weak self] error in
            Task { @MainActor [weak self] in await self?.failConnection(error) }
        })
        canRecordScreen = try remote.supports("com.apple.coredevice.feature.screenrecording")
        for key in ["isConnected", "isDisconnected"] { view.addObserver(self, forKeyPath: key, options: [.new], context: nil) }
        observing = true
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pendingStart = continuation
                requested = true
                do {
                    try unsafe connect.unsafeInvoke(on: view, NSOrderedSet(object: url), nil, options)
                    if try unsafe connected.unsafeInvoke(on: view) { connectionChanged() }
                } catch { finishStart(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishStart(throwing: CancellationError()) }
        }
    }

    func captureScreenshot() async throws -> CGImage {
        try Task.checkCancellation()
        guard !stopped, let image = try unsafe copyImage.unsafeInvoke(on: view) else {
            throw CLIError.unavailable("remote-screen-image", "The remote screen has not supplied an image to capture.")
        }
        return image.takeRetainedValue()
    }

    func send(_ input: RemoteScreenInput) async throws { try await self.input.send(input) }
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        try await remote.startRecording(displayUniqueID: displayUniqueID)
    }
    func releaseInputs() async throws { try await input.releaseInputs() }

    func stop() async throws {
        if let stopping { try await stopping.value; return }
        stopped = true
        events = nil
        canRecordScreen = false
        finishStart(throwing: CancellationError())
        removeObservers()
        let task = Task { [self] in
            await capabilityObservation.stop()
            var failure: (any Error)?
            do { try await input.releaseInputs() } catch { failure = error }
            do { try unsafe close.unsafeInvoke(on: view) }
            catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
            view.removeFromSuperview()
            if let failure { throw failure }
        }
        stopping = task
        defer { stopping = nil }
        try await task.value
    }

    private func failConnection(_ error: any Error) async {
        guard !stopped else { return }
        let notify = events
        let starting = pendingStart
        pendingStart = nil
        var failure = error
        do { try await stop() }
        catch { failure = RemoteDeviceScreenSession.combining(failure, cleanup: error) }
        if let starting { starting.resume(throwing: failure) }
        else { notify?(.failure(failure)) }
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                          change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "isConnected" || keyPath == "isDisconnected" else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        Task { @MainActor [weak self] in self?.connectionChanged() }
    }

    private func connectionChanged() {
        guard !stopped, requested else { return }
        do {
            if try unsafe connected.unsafeInvoke(on: view) {
                let continuation = pendingStart
                pendingStart = nil
                continuation?.resume()
                events?(.connected)
            } else if try unsafe disconnected.unsafeInvoke(on: view) {
                let error = CLIError.io("screen-sharing-disconnected", "The remote Screen Sharing connection ended.")
                Task { @MainActor [weak self] in await self?.failConnection(error) }
            }
        } catch {
            Task { @MainActor [weak self] in await self?.failConnection(error) }
        }
    }

    private func finishStart(throwing error: any Error) {
        let continuation = pendingStart
        pendingStart = nil
        continuation?.resume(throwing: error)
    }

    private func removeObservers() {
        guard observing else { return }
        observing = false
        for key in ["isConnected", "isDisconnected"] { view.removeObserver(self, forKeyPath: key) }
    }
}

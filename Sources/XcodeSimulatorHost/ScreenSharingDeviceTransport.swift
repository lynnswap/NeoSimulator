import ABIBridge
import AppKit

@MainActor
final class ScreenSharingDeviceTransport: NSObject, RemoteScreenTransport {
    private let input: CoreDeviceScreenInput
    private let url: URL
    private let view: NSView
    private let options: AnyObject
    private let connect: NativeObjCMethod<Void, NSOrderedSet, NSOrderedSet?, AnyObject>
    private let close: NativeObjCMethod<Void>
    private let connected: NativeObjCMethod<Bool>
    private let disconnected: NativeObjCMethod<Bool>
    private var pendingStart: CheckedContinuation<Void, any Error>?
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var observing = false
    private var stopped = false
    private var requested = false
    private(set) var inputCapabilities: Set<RemoteDeviceInputKind> = []
    var nativeInputView: NSView? { view }

    init(remote: CoreDeviceRemoteScreenDevice, url: URL, contentView: NSView) throws {
        try CoreDeviceRemoteScreenDevice.load("/System/Library/PrivateFrameworks/ScreenSharing.framework/ScreenSharing")
        guard let viewClass = NSClassFromString("SSSessionView") as? NSView.Type,
              let optionsClass = NSClassFromString("SSConnectionOptions") else {
            throw CLIError.unavailable("screen-sharing-runtime", "Screen Sharing is unavailable with this version of macOS.")
        }
        self.url = url
        input = CoreDeviceScreenInput(remote: remote)
        view = viewClass.init(frame: contentView.bounds)
        view.autoresizingMask = [.width, .height]
        let runtime = remote.runtime
        let defaults = try runtime.resolveAndWait(.message("defaultOptions", as: (() -> AnyObject).self), on: optionsClass, classMethod: true)
        options = try unsafe defaults.unsafeInvoke(on: optionsClass)
        let share = try runtime.resolveAndWait(.message("setShouldSharePasteboard:", as: ((Bool) -> Void).self), on: Swift.type(of: options))
        try unsafe share.unsafeInvoke(on: options, false)
        for selector in ["setShouldSharePasteboard:", "setShouldAllowSendPasteboard:"] {
            let disable = try runtime.resolveAndWait(.message(selector, as: ((Bool) -> Void).self), on: viewClass)
            try unsafe disable.unsafeInvoke(on: view, false)
        }
        connect = try runtime.resolveAndWait(.message("connectToURLs:withPreferredCredentials:options:",
            as: ((NSOrderedSet, NSOrderedSet?, AnyObject) -> Void).self), on: viewClass)
        close = try runtime.resolveAndWait(.message("closeSession", as: (() -> Void).self), on: viewClass)
        connected = try runtime.resolveAndWait(.message("isConnected", as: (() -> Bool).self), on: viewClass)
        disconnected = try runtime.resolveAndWait(.message("isDisconnected", as: (() -> Bool).self), on: viewClass)
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
        inputCapabilities = try input.capabilities()
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

    func send(_ input: RemoteScreenInput) async throws { try await self.input.send(input) }

    func stop() async throws {
        stopped = true
        events = nil
        inputCapabilities = []
        finishStart(throwing: CancellationError())
        removeObservers()
        var failure: (any Error)?
        do { try await input.releaseInputs() } catch { failure = error }
        do { try unsafe close.unsafeInvoke(on: view) }
        catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
        view.removeFromSuperview()
        if let failure { throw failure }
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
                if pendingStart != nil { finishStart(throwing: error) }
                else { events?(.failure(error)) }
            }
        } catch {
            if pendingStart != nil { finishStart(throwing: error) }
            else { events?(.failure(error)) }
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

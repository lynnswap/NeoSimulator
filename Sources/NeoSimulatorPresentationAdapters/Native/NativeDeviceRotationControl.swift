import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import Observation
import SwiftUI

/// Hosts the Duo plugin's rotation and posture controls with their native orientation state.
@MainActor @Observable
package final class NativeDevicePoseControls {
    package var isEnabled = true
    package var isAvailable: Bool { content != nil }
    /// Receives the controls' failures, including one from before the window that presents them connected.
    @ObservationIgnored package var onError: ((any Error) -> Void)? {
        didSet {
            guard let onError, let failure = unreportedFailure else { return }
            unreportedFailure = nil
            onError(failure)
        }
    }
    package struct Controls {
        package let rotation: AnyView
        package let postures: AnyView
        package let divider: AnyView?

        package init(rotation: AnyView, postures: AnyView, divider: AnyView?) {
            self.rotation = rotation
            self.postures = postures
            self.divider = divider
        }
    }
    /// Provider content without the standalone toolbar's sizing or button style.
    package var actionBarControls: [AnyView] {
        guard let content else { return [] }
        return [content.rotation] + (content.divider.map { [$0] } ?? []) + [content.postures]
    }

    private var content: Controls?
    @ObservationIgnored private var readProviders: (() throws -> [Any])?
    @ObservationIgnored private var prepareControls: (@MainActor ([Any]) async throws -> (() throws -> Controls?)?)?
    @ObservationIgnored private var discoveryGeneration = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var unreportedFailure: (any Error)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored package lazy var rotationView: NSView = makeView(postures: false)
    @ObservationIgnored package lazy var postureView: NSView = makeView(postures: true)

    private func makeView(postures: Bool) -> NSView {
        let host = NSHostingView(rootView: Content(model: self, postures: postures))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: postures ? 100 : 32),
            host.heightAnchor.constraint(equalToConstant: 28),
        ])
        return host
    }

    /// Starts finding the device's controls, which the screen they accompany does not wait for: they appear when found.
    package convenience init(deviceIdentifier: UUID) {
        self.init { try await $0.connect(deviceIdentifier: deviceIdentifier) }
    }

    /// Runs `prepare` until `disconnect()`, keeping its failure for `onError`.
    package init(prepare: @escaping @MainActor (NativeDevicePoseControls) async throws -> Void) {
        preparation = Task { [weak self] in
            guard let self else { return }
            do { try await prepare(self) }
            catch is CancellationError {}
            catch { report(error) }
        }
    }

    private func connect(deviceIdentifier: UUID) async throws {
        let runtime = ABIRuntime.shared
        let bindings = try await runtime.prepare { try await NativeActionBarBindings(runtime: $0) }
        let plugins = try unsafe bindings.shared.unsafeInvoke()
        guard !stopped else { return }
        try await discover(
            readProviders: { try bindings.providers(in: plugins) },
            prepareControls: { [weak self] values in
            for value in values where String(reflecting: type(of: value)) == "CoreDevicePopDeviceKitExtension.PosesActionBarControlProvider" {
                    let read = try await bindings.controls(of: value, for: deviceIdentifier) { [weak self] error in
                        self?.report(error)
                    }
                return {
                    var rotation: AnyView?, postures: AnyView?, divider: AnyView?
                        for control in try read() {
                            let name = try bindings.name(of: control)
                        guard name == "com.apple.dt.coredevicepop.actionbar.control.v68.rotate" ||
                                name == "com.apple.dt.coredevicepop.actionbar.control.v68.poses" ||
                                name == "com.apple.dt.coredevicepop.actionbar.control.v68.rotateDivider" else { continue }
                            let content = try bindings.view(of: control)
                        if name.hasSuffix(".rotate") { rotation = content }
                        else if name.hasSuffix(".rotateDivider") { divider = content }
                        else { postures = content }
                    }
                    guard let rotation, let postures else { return nil }
                    return Controls(rotation: rotation, postures: postures, divider: divider)
                }
            }
            return nil
        })
    }

    /// Finds the controls now and whenever what `readProviders` or the reader from `prepareControls` read changes. The
    /// reader that `prepareControls` returns reads the provider's controls, which it does not offer while CoreDevice
    /// reports the device as shut down.
    package func discover(readProviders: @escaping () throws -> [Any],
                          prepareControls: @escaping @MainActor ([Any]) async throws -> (() throws -> Controls?)?) async throws {
        self.readProviders = readProviders
        self.prepareControls = prepareControls
        try await discover()
    }

    private func report(_ error: any Error) {
        guard !stopped else { return }
        if let onError { onError(error) } else { unreportedFailure = error }
    }

    private func discover() async throws {
        guard !stopped, content == nil, let readProviders, let prepareControls else { return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let providers = discoveringAgainOnChange { Result { try readProviders() } }
        let readControls = try await prepareControls(providers.get())
        guard !stopped, discoveryGeneration == generation, content == nil, let readControls else { return }
        if let control = try discoveringAgainOnChange({ Result { try readControls() } }).get() {
            content = control
            self.readProviders = nil
            self.prepareControls = nil
        }
    }

    private func discoveringAgainOnChange<Value>(_ read: () -> Value) -> Value {
        withObservationTracking(read) { [weak self] in
            Task { @MainActor [weak self] in
                do { try await self?.discover() }
                catch { self?.report(error) }
            }
        }
    }

    package func disconnect() {
        stopped = true
        preparation?.cancel()
        preparation = nil
        unreportedFailure = nil
        discoveryGeneration += 1
        readProviders = nil
        prepareControls = nil
        content = nil
        onError = nil
    }

    // These bounds belong to the standalone renderer toolbar; the canvas styles raw controls.
    private struct ToolbarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
    }

    private struct Content: View {
        weak var model: NativeDevicePoseControls?
        let postures: Bool
        var body: some View {
            if let model, let content = model.content {
                (postures ? content.postures : content.rotation)
                    .labelStyle(.iconOnly)
                    .buttonStyle(ToolbarButtonStyle())
                    .font(.system(size: 15))
                    .disabled(!model.isEnabled)
                    .frame(width: postures ? 100 : 32, height: 28)
            }
        }
    }
}

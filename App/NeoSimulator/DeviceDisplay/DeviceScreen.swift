import AppKit
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

/// One device screen open in the manager. It keeps the screen's canvas controls current, dispatches their actions,
/// and moves the controller's presentation when the presentation owner asks.
///
/// The controller retains the connection; `DeviceScreens` registers the screen and ends it.
@MainActor @Observable
final class DeviceScreen {
    enum Controller {
        case simulator(DeviceWindowController)
        case remote(RemoteDeviceWindowController)
    }

    let id: DeviceInventoryID
    let controller: Controller
    let canvasControls = DeviceCanvasControls()
    /// Advances after each update of `canvasControls`, so the pane can fit the accessory that shows them.
    private(set) var canvasControlsUpdates = 0
    /// Changes that Observation cannot record: the remote controller's callback, a simulator session replacement,
    /// and dispatched actions. The state accessors read it through `observedController`.
    private var reportedChanges = 0
    @ObservationIgnored private let model: SimulatorManagerModel
    @ObservationIgnored private weak var screens: DeviceScreens?
    @ObservationIgnored private var isObserving = false

    init(id: DeviceInventoryID, controller: Controller, model: SimulatorManagerModel, screens: DeviceScreens) {
        self.id = id
        self.controller = controller
        self.model = model
        self.screens = screens
        canvasControls.onAction = { [weak self] action in self?.perform(action) }
        switch controller {
        case .simulator(let controller):
            controller.canvasControls = canvasControls
            controller.onSessionChange = { [weak self] in self?.reportedChanges += 1 }
        case .remote(let controller):
            controller.canvasControls = canvasControls
            controller.onChange = { [weak self] in self?.reportedChanges += 1 }
        }
    }

    // MARK: Observation

    func startObserving() {
        isObserving = true
        observe()
    }

    func stopObserving() { isObserving = false }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking { updateCanvasControls() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        canvasControlsUpdates += 1
    }

    private func updateCanvasControls() {
        let posture = model.devicePostures[id]
        let enabled = canControlDevice && !model.managingDeviceIDs.contains(id)
        canvasControls.xcodeURL = screens?.displayXcodeURL
        let available = model.inventory.first { $0.id == id }
            .map { DevicePostureModel.canInspect(capabilities: $0.capabilities) } ?? false
        canvasControls.update(supports: { action in
            action == "rotate" && posture?.isSupported == true ? false : supports(action)
        }, isEnabled: isEnabled, recordingTitle: recordingTitle,
                              recordingStartDate: recordingStartDate, nativePoses: nativePoseControls,
                              nativePosesEnabled: enabled, posture: posture, postureEnabled: enabled, postureAvailable: available,
                              pairedDeviceName: model.activePairedDevice(for: id)?.name)
    }

    /// The controller, read together with the changes it reports outside Observation.
    private var observedController: Controller {
        _ = reportedChanges
        return controller
    }

    // MARK: State

    var commandTarget: NSResponder {
        switch controller {
        case .simulator(let controller): controller
        case .remote(let controller): controller
        }
    }

    var canControlDevice: Bool {
        switch observedController {
        case .simulator(let controller): controller.session.canPerformCommands
        case .remote(let controller): controller.session.state == .connected
        }
    }

    var nativePoseControls: NativeDevicePoseControls? {
        guard case .simulator(let controller) = observedController else { return nil }
        return controller.session.display.nativePoseControls
    }

    /// The simulator's capabilities, which assign the shared shortcuts of device commands.
    var simulatorCapabilities: DeviceCapabilities? {
        guard case .simulator(let controller) = observedController else { return nil }
        return controller.session.capabilities
    }

    func supports(_ identifier: String) -> Bool {
        switch observedController {
        case .simulator(let controller):
            if CanvasZoom.Action(rawValue: identifier) != nil { return true }
            guard let id = Self.simulatorCommand(identifier, for: controller) else { return false }
            return id == .resizeApp ? controller.session.supportsAppResize : DeviceCommand.command(id).isSupported(controller.session.capabilities)
        case .remote(let controller):
            if CanvasZoom.Action(rawValue: identifier) != nil { return false }
            return identifier == "resizeApp" ? controller.session.supportsAppResize : identifier != "rotate"
        }
    }

    func isEnabled(_ identifier: String) -> Bool {
        switch observedController {
        case .simulator(let controller):
            if let action = CanvasZoom.Action(rawValue: identifier) { return controller.canPerformCanvasZoom(action) }
            guard let id = Self.simulatorCommand(identifier, for: controller) else { return false }
            return DeviceCommand.command(id).isEnabled(controller)
        case .remote(let controller): return controller.isScreenActionEnabled(identifier)
        }
    }

    var resizingApp: Bool {
        switch observedController {
        case .simulator(let controller): controller.session.isResizingApp || controller.session.isStartingAppResize
        case .remote(let controller): controller.session.isResizingApp || controller.session.isChangingDisplay
        }
    }

    func canvasZoomIsSelected(_ identifier: String) -> Bool {
        guard let action = CanvasZoom.Action(rawValue: identifier),
              case .simulator(let controller) = observedController else { return false }
        return controller.canvasZoomIsSelected(action)
    }

    var recordingTitle: String {
        switch observedController {
        case .simulator(let controller): controller.session.recording == nil ? "Record Screen" : "Stop Recording"
        case .remote(let controller): controller.screenActionPresentation("record")?.title ?? "Record Screen"
        }
    }

    var recordingStartDate: Date? {
        switch observedController {
        case .simulator(let controller): controller.session.recording?.startDate
        case .remote(let controller): controller.session.recordingStartDate
        }
    }

    var capturesKeyboard: Bool {
        switch observedController {
        case .simulator(let controller): controller.capturesKeyboard
        case .remote(let controller): controller.capturesKeyboard
        }
    }

    // MARK: Actions

    /// Sends a canvas or toolbar action to the device while this screen is open.
    func perform(_ action: String) {
        guard let screens, screens.screen(for: id) === self else { return }
        if action == "pairedDevice" {
            model.openActivePairedDevice(for: id)
            return
        }
        if action.hasPrefix("posture."), let posture = DevicePosture(rawValue: String(action.dropFirst("posture.".count))),
           let source = model.devicePostures[id], canControlDevice, !model.managingDeviceIDs.contains(id) {
            // The selection reports its failure after this screen may have closed.
            Task { [weak screens] in
                do { try await source.select(posture) }
                catch is CancellationError {}
                catch { screens?.onError?(error) }
            }
            if case .simulator(let controller) = controller { controller.focusInput() }
            reportedChanges += 1
            return
        }
        guard supports(action), isEnabled(action) else { return }
        switch controller {
        case .simulator(let controller):
            if let zoom = CanvasZoom.Action(rawValue: action) { controller.performCanvasZoom(zoom) }
            else if let command = Self.simulatorCommand(action, for: controller) { controller.perform(command) }
        case .remote(let controller): controller.performScreenAction(action)
        }
        reportedChanges += 1
    }

    private static func simulatorCommand(_ identifier: String, for controller: DeviceWindowController) -> DeviceCommand.ID? {
        switch identifier {
        case "home": .home
        case "lock": .lock
        case "rotate": DeviceCommand.canvasRotation(modifierFlags: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
        case "resizeApp": .resizeApp
        case "capture": .saveScreen
        case "record": controller.session.recording == nil ? .recordScreen : .stopRecording
        case "captureKeyboard": .captureKeyboard
        default: nil
        }
    }

    // MARK: Presentation

    var presentation: SimulatorScreenRestoration.Presentation {
        switch controller {
        case .simulator(let controller): .init(isEmbedded: controller.isEmbedded, window: controller.window)
        case .remote(let controller): .init(isEmbedded: controller.isEmbedded, window: controller.window)
        }
    }

    func isEmbedded(in parent: NSViewController) -> Bool {
        let content = switch controller {
        case .simulator(let controller): controller.presentationViewController
        case .remote(let controller): controller.presentationViewController as NSViewController
        }
        return content.parent === parent && content.view.superview === parent.view
    }

    func validatePresentationMove() throws {
        let canMove = switch controller {
        case .simulator(let controller): controller.canMovePresentation
        case .remote(let controller): controller.canMovePresentation
        }
        guard canMove else {
            throw HostError.operation("Close the device's dialog or leave full screen before moving its screen.")
        }
    }

    func preparePresentationMove() async throws {
        switch controller {
        case .simulator: try validatePresentationMove()
        case .remote(let controller): try await controller.preparePresentationMove()
        }
    }

    func embed(in parent: NSViewController) async throws {
        switch controller {
        case .simulator(let controller): controller.embed(in: parent)
        case .remote(let controller): try await controller.embed(in: parent)
        }
    }

    func showCompactWindow() async throws {
        switch controller {
        case .simulator(let controller): controller.showCompactWindow()
        case .remote(let controller): try await controller.showCompactWindow()
        }
    }

    func detach() async throws {
        switch controller {
        case .simulator(let controller): controller.detachPresentation()
        case .remote(let controller): try await controller.detachPresentation()
        }
    }
}

extension SimulatorScreenRestoration.Presentation {
    /// Where a screen's controller presents it.
    @MainActor init(isEmbedded: Bool, window: NSWindow?) {
        self = isEmbedded ? .main : window?.isVisible == true ? .compact : .hidden
    }
}

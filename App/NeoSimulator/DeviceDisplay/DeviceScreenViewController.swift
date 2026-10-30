import AppKit
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The manager's center pane, which shows the selected device's live screen or its preview.
/// The manager window owns the selection and toolbar, and attaches `canvasAccessory` to this pane's split view item.
@MainActor
final class DeviceScreenViewController: NSViewController {
    private let model: SimulatorManagerModel
    let liveScreenContainer = NSViewController()
    let canvasAccessory = DeviceCanvasAccessoryViewController()
    private(set) var liveDeviceIdentifier: DeviceInventoryID?
    private(set) weak var liveCommandTarget: NSResponder?
    var onLiveScreenChange: (() -> Void)?
    var onViewScreen: (() -> Void)?
    private let previewStack = NSStackView()
    private let deviceImage = NSImageView()
    private let deviceName = NSTextField(labelWithString: "Select a Device")
    private let deviceRuntime = NSTextField(labelWithString: "")
    private let viewScreen = NSButton(title: "View Screen", target: nil, action: nil)
    private var previewTask: Task<Void, Never>?
    private var previewArtwork: DeviceArtworkModel?
    private let deviceFooter = NSStackView()
    private let activityStack = NSStackView()
    private let cancelOpening = NSButton(title: "Cancel Opening Screens", target: nil, action: nil)
    /// The footer's distance from the pane's safe area, and the space it leaves above itself.
    private static let footerInset: CGFloat = 8, footerSpacing: CGFloat = 12
    private let activity = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    init(model: SimulatorManagerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let view = NSView()
        self.view = view
        liveScreenContainer.view = NSView()
        addChild(liveScreenContainer)
        let liveView = liveScreenContainer.view
        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.isHidden = true
        liveView.clipsToBounds = true
        view.addSubview(liveView)
        // Presentations may draw behind the toolbar, bottom accessory and footer; each keeps its content in the safe area.
        NSLayoutConstraint.activate([
            liveView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            liveView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            liveView.topAnchor.constraint(equalTo: view.topAnchor),
            liveView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        deviceImage.imageScaling = .scaleProportionallyUpOrDown
        deviceImage.translatesAutoresizingMaskIntoConstraints = false
        deviceImage.setAccessibilityHidden(true)
        deviceName.font = .systemFont(ofSize: 17, weight: .semibold)
        deviceName.alignment = .center
        deviceName.lineBreakMode = .byTruncatingTail
        deviceRuntime.font = .systemFont(ofSize: 13)
        deviceRuntime.textColor = .secondaryLabelColor
        deviceRuntime.alignment = .center
        deviceRuntime.lineBreakMode = .byTruncatingTail
        viewScreen.bezelStyle = .rounded
        viewScreen.controlSize = .large
        viewScreen.image = NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.imagePosition = .imageLeading
        viewScreen.target = self
        viewScreen.action = #selector(requestScreen(_:))
        for preview in [deviceImage, deviceName, deviceRuntime, viewScreen] { previewStack.addArrangedSubview(preview) }
        previewStack.orientation = .vertical
        previewStack.alignment = .centerX
        previewStack.spacing = 10
        previewStack.setCustomSpacing(24, after: deviceImage)
        previewStack.setCustomSpacing(20, after: deviceRuntime)
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewStack)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        activity.font = .systemFont(ofSize: 12)
        activity.textColor = .secondaryLabelColor
        activity.lineBreakMode = .byTruncatingTail
        activityStack.addArrangedSubview(progress)
        activityStack.addArrangedSubview(activity)
        cancelOpening.controlSize = .small
        cancelOpening.bezelStyle = .rounded
        cancelOpening.target = self
        cancelOpening.action = #selector(cancelPendingScreenOpens(_:))
        cancelOpening.isHidden = true
        activityStack.addArrangedSubview(cancelOpening)
        activityStack.orientation = .horizontal
        activityStack.alignment = .centerY
        activityStack.spacing = 7
        activityStack.isHidden = true
        deviceFooter.orientation = .vertical
        deviceFooter.alignment = .centerX
        deviceFooter.spacing = 8
        deviceFooter.translatesAutoresizingMaskIntoConstraints = false
        deviceFooter.addArrangedSubview(activityStack)
        deviceFooter.isHidden = true
        view.addSubview(deviceFooter)
        NSLayoutConstraint.activate([
            deviceImage.widthAnchor.constraint(equalToConstant: 192),
            deviceImage.heightAnchor.constraint(equalToConstant: 192),
            viewScreen.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            previewStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            previewStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            previewStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            deviceName.widthAnchor.constraint(lessThanOrEqualTo: previewStack.widthAnchor),
            deviceRuntime.widthAnchor.constraint(lessThanOrEqualTo: previewStack.widthAnchor),
            deviceFooter.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            deviceFooter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Self.footerInset),
            deviceFooter.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            deviceFooter.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeActivity()
    }

    private func observeActivity() {
        withObservationTracking { updateActivity() } onChange: { [weak self] in
            Task { @MainActor in self?.observeActivity() }
        }
    }

    private func updateActivity() {
        activity.stringValue = model.isBusy ? model.activity : (model.backgroundIssue ?? "")
        activity.toolTip = activity.stringValue
        activity.isHidden = activity.stringValue.isEmpty
        progress.isHidden = !model.isBusy
        if model.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        cancelOpening.isHidden = model.openingDeviceIDs.isEmpty
        activityStack.isHidden = activity.isHidden && progress.isHidden && cancelOpening.isHidden
        updateDeviceFooter()
    }

    private func updateDeviceFooter() {
        deviceFooter.isHidden = activityStack.isHidden
        // A live screen keeps drawing behind the footer; the footer only narrows the area it fits within.
        let liveView = liveScreenContainer.view
        var insets = liveView.additionalSafeAreaInsets
        insets.bottom = deviceFooter.isHidden ? 0
            : Self.footerInset + deviceFooter.fittingSize.height + Self.footerSpacing
        liveView.additionalSafeAreaInsets = insets
    }

    func updatePreview(for device: InventoryDevice, details: String, artwork: DeviceArtworkModel, canViewScreen: Bool) {
        deviceName.stringValue = device.name
        deviceRuntime.stringValue = details
        if previewArtwork !== artwork {
            previewTask?.cancel()
            previewArtwork = artwork
            deviceImage.image = nil
            previewTask = Task { [weak self] in
                let image = await artwork.hardwarePreview()
                guard !Task.isCancelled, let self else { return }
                self.deviceImage.image = image
            }
        }
        deviceImage.contentTintColor = nil
        updateViewScreen(for: device, isEnabled: canViewScreen)
    }

    func updatePreview(selectionCount: Int) {
        previewTask?.cancel()
        previewTask = nil
        previewArtwork = nil
        if selectionCount == 0 {
            deviceName.stringValue = "Select a Device"
            deviceRuntime.stringValue = "Choose a device in the sidebar to view its details."
            deviceImage.image = nil
        } else {
            deviceName.stringValue = "\(selectionCount) Devices"
            deviceRuntime.stringValue = "Select one device to view its details."
            deviceImage.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        }
        deviceImage.contentTintColor = nil
        updateViewScreen(for: nil, isEnabled: false)
    }

    private func updateViewScreen(for device: InventoryDevice?, isEnabled: Bool) {
        let isOpening = device.map { model.openingDeviceIDs.contains($0.id) } == true
        let isShutdown: Bool
        if case .simulator(let simulator)? = device { isShutdown = simulator.state == "Shutdown" } else { isShutdown = false }
        viewScreen.title = isOpening ? "Cancel Opening" : (isShutdown ? "Start" : "View Screen")
        viewScreen.image = isShutdown ? nil : NSImage(systemSymbolName: "rectangle.badge.person.crop", accessibilityDescription: nil)
        viewScreen.isHidden = device == nil
        viewScreen.isEnabled = isEnabled
        viewScreen.toolTip = nil
    }

    func showLiveScreen(for identifier: DeviceInventoryID, controls: DeviceCanvasControls?, commandTarget: NSResponder) {
        liveDeviceIdentifier = identifier
        liveCommandTarget = commandTarget
        canvasAccessory.setControls(controls)
        liveScreenContainer.view.isHidden = false
        previewStack.isHidden = true
        onLiveScreenChange?()
    }

    func showDevicePreview(ifDisplaying identifier: DeviceInventoryID) {
        guard liveDeviceIdentifier == identifier else { return }
        liveDeviceIdentifier = nil
        canvasAccessory.setControls(nil)
        liveCommandTarget = nil
        liveScreenContainer.view.isHidden = true
        previewStack.isHidden = false
        onLiveScreenChange?()
        updateDeviceFooter()
    }

    @objc private func requestScreen(_ sender: Any?) { onViewScreen?() }

    @objc private func cancelPendingScreenOpens(_ sender: Any?) { model.cancelPendingOpens() }
}

import AppKit
import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

/// Device Hub-style controls retained with the screen across presentations.
@MainActor
final class DeviceCanvasControls: NSView {
    var onAction: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?
    var xcodeURL: URL?
    private let screenActionBar = NSStackView()
    private var modifierMonitor: Any?
    private let screenActionIdentifiers = ["home", "capture", "record", "rotate"]
    private let primaryScreenActions = NSGlassEffectView()
    private let screenRecordingTimer = NSHostingView(rootView: AnyView(EmptyView()))
    private let profileScreenActions = NSGlassEffectView()
    private var screenActionButtons: [String: NSButton] = [:]
    private var postureButtons: [DevicePosture: NSButton] = [:]
    private let nativeRotationContainer = NSStackView()
    private let nativePostureContainer = NSStackView()
    private let rotationDivider = NSBox()
    private var screenActionArtworkXcodeURL: URL?
    private var screenActionArtworkTask: Task<Void, Never>?
    private var screenRotationImages: [DeviceCommand.ID: NSImage] = [:]

    init() {
        super.init(frame: .zero)
        buildScreenActionBar()
        isHidden = true
        screenActionBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(screenActionBar)
        NSLayoutConstraint.activate([
            screenActionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            screenActionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            screenActionBar.topAnchor.constraint(equalTo: topAnchor),
            screenActionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        screenRecordingTimer.setAccessibilityLabel("Recording Time")
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateRotationButton(modifierFlags: event.modifierFlags)
            return event
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onLayoutChange?()
    }

    override func layout() {
        super.layout()
        for glass in [primaryScreenActions, profileScreenActions] {
            glass.cornerRadius = glass.bounds.height / 2
        }
    }

    isolated deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        screenActionArtworkTask?.cancel()
    }

    private func buildScreenActionBar() {
        screenActionBar.orientation = .horizontal
        screenActionBar.alignment = .centerY
        screenActionBar.distribution = .fill
        screenActionBar.spacing = 8
        screenActionBar.isHidden = true
        screenActionBar.setAccessibilityLabel("Device Actions")
        for (identifiers, glass) in [(["home", "capture", "record"], primaryScreenActions),
                                      (["rotate"], profileScreenActions)] {
            let controls = NSStackView()
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.distribution = .fill
            controls.spacing = 2
            controls.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            for identifier in identifiers {
                if identifier == "record" {
                    screenRecordingTimer.isHidden = true
                    controls.addArrangedSubview(screenRecordingTimer)
                }
                let (title, symbol): (String, String?) = switch identifier {
                case "home": ("Home", "app.grid.3x3")
                case "capture": ("Save Screenshot…", "camera.viewfinder")
                case "record": ("Record Screen", "record.circle")
                default: ("Rotate", nil)
                }
                let button = NSButton(title: title, target: self, action: #selector(performScreenAction(_:)))
                button.image = symbol.flatMap { NSImage.deviceControlSymbol(named: $0, accessibilityDescription: title) }
                button.imagePosition = button.image == nil ? .noImage : .imageOnly
                button.identifier = NSUserInterfaceItemIdentifier(identifier)
                button.bezelStyle = .accessoryBarAction
                button.controlSize = .regular
                button.font = .systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
                button.symbolConfiguration = .init(textStyle: .body, scale: .medium)
                button.isBordered = false
                button.imageScaling = .scaleProportionallyDown
                button.contentTintColor = .labelColor
                button.toolTip = title
                button.setAccessibilityLabel(title)
                button.translatesAutoresizingMaskIntoConstraints = false
                controls.addArrangedSubview(button)
                screenActionButtons[identifier] = button
            }
            if glass === profileScreenActions {
                controls.insertArrangedSubview(nativeRotationContainer, at: 0)
                nativeRotationContainer.isHidden = true
                rotationDivider.boxType = .separator
                rotationDivider.translatesAutoresizingMaskIntoConstraints = false
                controls.addArrangedSubview(rotationDivider)
                NSLayoutConstraint.activate([
                    rotationDivider.widthAnchor.constraint(equalToConstant: 1),
                    rotationDivider.heightAnchor.constraint(equalTo: controls.heightAnchor, constant: -8),
                ])
                rotationDivider.isHidden = true
                controls.addArrangedSubview(nativePostureContainer)
                nativePostureContainer.isHidden = true
                for posture in DevicePosture.allCases {
                    let button = NSButton(title: posture.title, target: self, action: #selector(performScreenAction(_:)))
                    button.imagePosition = .noImage
                    button.identifier = NSUserInterfaceItemIdentifier("posture." + posture.rawValue)
                    button.setButtonType(.pushOnPushOff)
                    button.bezelStyle = .accessoryBarAction
                    button.controlSize = .regular
                    button.font = .systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
                    button.symbolConfiguration = .init(textStyle: .body, scale: .medium)
                    button.isBordered = false
                    button.isHidden = true
                    button.toolTip = posture.title
                    button.setAccessibilityLabel(posture.title)
                    button.translatesAutoresizingMaskIntoConstraints = false
                    controls.addArrangedSubview(button)
                    postureButtons[posture] = button
                }
            }
            glass.style = .regular
            controls.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = controls
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                controls.topAnchor.constraint(equalTo: glass.topAnchor),
                controls.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            screenActionBar.addArrangedSubview(glass)
        }
    }

    private func installNativeControl(_ view: NSView?, in container: NSStackView) {
        if container.arrangedSubviews.first !== view || view.map({ $0.superview !== container }) == true {
            for child in container.arrangedSubviews {
                container.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
            if let view { container.addArrangedSubview(view) }
        }
        container.isHidden = view == nil
    }

    func update(supports: (String) -> Bool, isEnabled: (String) -> Bool, recordingTitle: String, recordingStartDate: Date? = nil,
                             nativePoses: NativeDevicePoseControls? = nil, nativePosesEnabled: Bool = true) {
        let showsNative = nativePoses?.isAvailable == true
        installNativeControl(showsNative ? nativePoses?.rotationView : nil, in: nativeRotationContainer)
        installNativeControl(showsNative ? nativePoses?.postureView : nil, in: nativePostureContainer)
        nativePoses?.isEnabled = nativePosesEnabled
        loadScreenActionArtworkIfNeeded()
        for identifier in screenActionIdentifiers {
            guard let button = screenActionButtons[identifier] else { continue }
            button.isHidden = !supports(identifier)
            button.isEnabled = isEnabled(identifier)
            if identifier == "record" {
                let symbol = switch recordingTitle {
                case "Stop Recording": "stop.fill"
                case "Save Recording…": "square.and.arrow.down"
                default: "record.circle"
                }
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: recordingTitle)
                button.symbolConfiguration = .init(textStyle: .body,
                                                   scale: recordingTitle == "Stop Recording" ? .small : .medium)
                button.contentTintColor = recordingTitle == "Stop Recording" ? .systemRed : .labelColor
                button.toolTip = recordingTitle
                button.setAccessibilityLabel(recordingTitle)
            }
        }
        if let recordingStartDate, screenActionButtons["record"]?.isHidden == false {
            screenRecordingTimer.rootView = AnyView(Text(recordingStartDate, style: .timer)
                .font(.body).monospacedDigit().fixedSize()
                .padding(.horizontal, 8))
            screenRecordingTimer.isHidden = false
        } else {
            screenRecordingTimer.isHidden = true
            screenRecordingTimer.rootView = AnyView(EmptyView())
        }
        updateRotationButton()
        primaryScreenActions.isHidden = ["home", "capture", "record"].allSatisfy {
            screenActionButtons[$0]?.isHidden != false
        }
        profileScreenActions.isHidden = screenActionButtons["rotate"]?.isHidden != false && nativeRotationContainer.isHidden
        screenActionBar.isHidden = primaryScreenActions.isHidden && profileScreenActions.isHidden
        isHidden = screenActionBar.isHidden
        invalidateIntrinsicContentSize()
        onLayoutChange?()
    }

    func updatePosture(_ model: DevicePostureModel?, isEnabled: Bool, available: Bool) {
        let visible = model?.isSupported == true
        let showsNative = !nativePostureContainer.isHidden
        rotationDivider.isHidden = (!visible && !showsNative) || nativeRotationContainer.isHidden
        for (posture, button) in postureButtons {
            button.isHidden = !visible || showsNative
            button.isEnabled = isEnabled && available && model?.canSelect == true
            button.state = model?.confirmedPosture == posture ? .on : .off
            button.contentTintColor = button.state == .on ? .controlAccentColor : .labelColor
            button.toolTip = model?.lastError?.localizedDescription ?? posture.title
        }
        profileScreenActions.isHidden = screenActionButtons["rotate"]?.isHidden != false && nativeRotationContainer.isHidden && !visible && !showsNative
        screenActionBar.isHidden = primaryScreenActions.isHidden && profileScreenActions.isHidden
        isHidden = screenActionBar.isHidden
        invalidateIntrinsicContentSize()
        onLayoutChange?()
    }

    private func loadScreenActionArtworkIfNeeded() {
        guard let xcodeURL = xcodeURL, xcodeURL != screenActionArtworkXcodeURL else { return }
        screenActionArtworkXcodeURL = xcodeURL
        screenActionArtworkTask?.cancel()
        screenRotationImages.removeAll()
        updateRotationButton()
        for button in postureButtons.values {
            button.image = nil
            button.imagePosition = .noImage
        }
        let catalogURL = xcodeURL.appendingPathComponent(
            "Contents/SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/Assets.car")
        screenActionArtworkTask = Task { [weak self] in
            let deviceKitCatalogURL = xcodeURL.appendingPathComponent("Contents/SharedFrameworks/DeviceKit.framework/Versions/A/Resources/Assets.car")
            var rotations: [DeviceCommand.ID: NSImage] = [:]
            for (command, symbol) in [(DeviceCommand.ID.rotateLeft, "rotate.device.left"), (.rotateRight, "rotate.device.right")] {
                let resource = try? await DeviceSymbolResource.load(named: symbol, from: deviceKitCatalogURL)
                guard !Task.isCancelled else { return }
                rotations[command] = resource?.image
            }
            var images: [DevicePosture: NSImage] = [:]
            for posture in DevicePosture.allCases {
                let name = switch posture {
                case .closed: "v68_Closed"
                case .partiallyOpen: "v68_HalfOpen_Landscape"
                case .open: "v68_Open"
                }
                let resource = try? await DeviceSymbolResource.load(named: name, from: catalogURL)
                guard !Task.isCancelled else { return }
                images[posture] = resource?.image
            }
            guard let self else { return }
            self.screenRotationImages = rotations
            self.updateRotationButton()
            for (posture, button) in self.postureButtons {
                button.image = images[posture]
                button.imagePosition = button.image == nil ? .noImage : .imageOnly
            }
        }
    }

    private func updateRotationButton(modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let button = screenActionButtons["rotate"] else { return }
        let command = DeviceCommand.canvasRotation(modifierFlags: modifierFlags)
        let title = DeviceCommand.command(command).title
        button.image = screenRotationImages[command]
        button.imagePosition = button.image == nil ? .noImage : .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    @objc private func performScreenAction(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        onAction?(identifier)
    }

}

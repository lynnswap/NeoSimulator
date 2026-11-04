import AppKit
import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

/// Bottom canvas content retained with the screen across presentations.
@MainActor
final class DeviceCanvasControls: NSView {
    var onAction: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?
    var xcodeURL: URL?
    private let host = CanvasControlsHostingView(rootView: CanvasBottomContent())
    private var content = CanvasBottomContent()
    private var modifierMonitor: Any?
    private var artworkXcodeURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var rotationImages: [DeviceCommand.ID: NSImage] = [:]
    private var postureImages: [DevicePosture: NSImage] = [:]

    init() {
        super.init(frame: .zero)
        isHidden = true
        host.sizingOptions = [.minSize, .intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.render(modifierFlags: event.modifierFlags)
            return event
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        artworkTask?.cancel()
    }

    func update(supports: (String) -> Bool, isEnabled: (String) -> Bool, recordingTitle: String,
                recordingStartDate: Date? = nil, nativePoses: NativeDevicePoseControls? = nil,
                nativePosesEnabled: Bool = true, posture: DevicePostureModel? = nil,
                postureEnabled: Bool = true, postureAvailable: Bool = true, pairedDeviceName: String? = nil) {
        content.actions = ["home", "capture", "record", "rotate"].filter(supports).map { identifier in
            let title = switch identifier {
            case "home": "Home"
            case "capture": "Save Screenshot…"
            case "record": recordingTitle
            default: DeviceCommand.command(DeviceCommand.canvasRotation(modifierFlags: NSEvent.modifierFlags)).title
            }
            let symbol: String? = switch identifier {
            case "home": "app.grid.3x3"
            case "capture": "camera.viewfinder"
            case "record": recordingTitle == "Stop Recording" ? "stop.fill" : recordingTitle == "Save Recording…" ? "square.and.arrow.down" : "record.circle"
            default: nil
            }
            return CanvasAction(id: identifier, title: title, symbol: symbol,
                                image: symbol.flatMap { NSImage.deviceControlSymbol(named: $0, accessibilityDescription: title) },
                                enabled: isEnabled(identifier))
        }
        content.pairedDeviceName = pairedDeviceName
        content.recordingStartDate = recordingStartDate
        content.nativePoses = nativePoses?.isAvailable == true ? nativePoses : nil
        content.nativePosesEnabled = nativePosesEnabled
        content.postures = posture?.isSupported == true && content.nativePoses == nil ? DevicePosture.allCases.map {
            CanvasAction(id: "posture." + $0.rawValue, title: $0.title,
                         enabled: postureEnabled && postureAvailable && posture?.canSelect == true,
                         selected: posture?.confirmedPosture == $0,
                         help: posture?.lastError?.localizedDescription)
        } : []
        loadArtworkIfNeeded()
        render()
    }

    private func render(modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let previousSize = fittingSize
        let wasHidden = isHidden
        let rotation = DeviceCommand.canvasRotation(modifierFlags: modifierFlags)
        for index in content.actions.indices where content.actions[index].id == "rotate" {
            content.actions[index].image = rotationImages[rotation]
            content.actions[index].title = DeviceCommand.command(rotation).title
        }
        for index in content.postures.indices {
            let id = content.postures[index].id
            content.postures[index].image = DevicePosture.allCases.first { "posture." + $0.rawValue == id }.flatMap { postureImages[$0] }
        }
        content.onAction = { [weak self] in self?.onAction?($0) }
        host.rootView = content
        isHidden = content.pairedDeviceName == nil && content.actions.isEmpty && content.postures.isEmpty && content.nativePoses == nil
        host.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        // Measure the hosting view's updated constraints before notifying the
        // window owner; style-only renders must preserve manual window geometry.
        updateConstraintsForSubtreeIfNeeded()
        if wasHidden != isHidden || previousSize != fittingSize { onLayoutChange?() }
    }

    private func loadArtworkIfNeeded() {
        guard let xcodeURL, xcodeURL != artworkXcodeURL else { return }
        artworkXcodeURL = xcodeURL
        artworkTask?.cancel()
        rotationImages.removeAll()
        postureImages.removeAll()
        artworkTask = Task { [weak self] in
            let deviceKitCatalog = xcodeURL.appendingPathComponent("Contents/SharedFrameworks/DeviceKit.framework/Versions/A/Resources/Assets.car")
            var rotations: [DeviceCommand.ID: NSImage] = [:]
            for (command, symbol) in [(DeviceCommand.ID.rotateLeft, "rotate.device.left"), (.rotateRight, "rotate.device.right")] {
                let resource = try? await DeviceSymbolResource.load(named: symbol, from: deviceKitCatalog)
                guard !Task.isCancelled else { return }
                rotations[command] = resource?.image
            }
            let postureCatalog = xcodeURL.appendingPathComponent("Contents/SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/Assets.car")
            var postures: [DevicePosture: NSImage] = [:]
            for posture in DevicePosture.allCases {
                let name = switch posture {
                case .closed: "v68_Closed"
                case .partiallyOpen: "v68_HalfOpen_Landscape"
                case .open: "v68_Open"
                }
                let resource = try? await DeviceSymbolResource.load(named: name, from: postureCatalog)
                guard !Task.isCancelled else { return }
                postures[posture] = resource?.image
            }
            guard let self else { return }
            self.rotationImages = rotations
            self.postureImages = postures
            self.render()
        }
    }
}

private struct CanvasAction: Identifiable {
    let id: String
    var title: String
    var symbol: String? = nil
    var image: NSImage? = nil
    var enabled: Bool
    var selected = false
    var help: String? = nil
}

@MainActor
private final class CanvasControlsHostingView: NSHostingView<CanvasBottomContent> {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        // The caption accepts the available width; SwiftUI still supplies the
        // action bar's minimum width and the content's natural height.
        return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
    }
}

private struct CanvasBottomContent: View {
    var pairedDeviceName: String?
    var actions: [CanvasAction] = []
    var postures: [CanvasAction] = []
    var recordingStartDate: Date?
    var nativePoses: NativeDevicePoseControls?
    var nativePosesEnabled = true
    var onAction: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let pairedDeviceName {
                Button { onAction("pairedDevice") } label: {
                    HStack {
                        Text("Paired with \(pairedDeviceName)").lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.right").fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pairedDevice")
                .padding(.top, 8)
            }
            actionBar
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionBar: some View {
        HStack {
            let primary = actions.filter { $0.id != "rotate" }
            if !primary.isEmpty {
                CanvasActionGroup(count: primary.count) {
                    ForEach(primary) { action in button(action) }
                }
            }
            let rotations = actions.filter { $0.id == "rotate" }
            if let nativePoses {
                let controls = nativePoses.actionBarControls
                CanvasActionGroup(count: controls.count) {
                    ForEach(controls.indices, id: \.self) { controls[$0] }
                }
                .disabled(!nativePosesEnabled)
            } else if !rotations.isEmpty || !postures.isEmpty {
                CanvasActionGroup(count: rotations.count + postures.count) {
                    ForEach(rotations) { action in button(action) }
                    ForEach(postures) { action in button(action) }
                }
            }
        }
        .fixedSize()
        .safeAreaPadding(.top, 8)
    }

    @ViewBuilder private func button(_ action: CanvasAction) -> some View {
        if action.id == "record", let recordingStartDate {
            HStack(spacing: 12) {
                Text(recordingStartDate, style: .timer).monospacedDigit().fixedSize()
                    .accessibilityLabel("Recording Time")
                actionButton(action)
            }
        } else {
            actionButton(action)
        }
    }

    private func actionButton(_ action: CanvasAction) -> some View {
        Button { onAction(action.id) } label: {
            if action.id == "record", action.title == "Stop Recording" {
                Image(systemName: "stop.fill").font(.caption2).foregroundStyle(.red)
            } else {
                Label {
                    Text(verbatim: action.title)
                } icon: {
                    if let image = action.image {
                        Image(nsImage: image.withSymbolConfiguration(.init(textStyle: .title3)) ?? image)
                    }
                    else if let symbol = action.symbol { Image(systemName: symbol) }
                    else { Text(verbatim: action.title) }
                }
            }
        }
        .disabled(!action.enabled)
        .foregroundStyle(action.selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .help(action.help ?? action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.id)
    }
}

private struct CanvasActionGroup<Content: View>: View {
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(count > 1 ? 4 : 0)
            .frame(height: 36)
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(CanvasActionButtonStyle(isGrouped: count > 1))
            .labelStyle(.iconOnly)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct CanvasActionButtonStyle: ButtonStyle {
    let isGrouped: Bool
    func makeBody(configuration: Configuration) -> some View {
        CanvasActionButtonBody(configuration: configuration, isGrouped: isGrouped)
            .frame(width: isGrouped ? 32 : nil)
            .labelStyle(.iconOnly)
            .contentShape(shape)
    }
    private var shape: AnyShape { isGrouped ? AnyShape(Capsule(style: .continuous)) : AnyShape(Circle()) }
}

private struct CanvasActionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isGrouped: Bool
    @State private var isHovered = false
    var body: some View {
        ZStack {
            shape.fill(background)
            configuration.label.font(.title3).fontWeight(.regular)
        }
        .onHover { isHovered = $0 }
    }
    private var shape: AnyShape { isGrouped ? AnyShape(Capsule(style: .continuous)) : AnyShape(Circle()) }
    private var background: Color {
        if configuration.isPressed { .primary.opacity(0.15) }
        else if isHovered { .secondary.opacity(0.1) }
        else { .clear }
    }
}

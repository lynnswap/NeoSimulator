import AppKit
import NeoSimulatorKit

/// The manager's commands use ordinary controls, keeping toolbar glass composition out of live resize.
@MainActor
final class ManagerCommandBar: NSView {
    let sidebar = button("Sidebar", symbol: "sidebar.left", identifier: "Sidebar")
    let settings = button("Settings", symbol: "gear", identifier: "Settings")
    let filter = button("Filter and Sort Devices", symbol: "line.3.horizontal.decrease", identifier: "FilterSimulators", toggle: true)
    let captureKeyboard = button("Capture Keyboard", symbol: "keyboard", identifier: "captureKeyboard", toggle: true)
    let resizeApp = button("Resize App", symbol: "aspectratio", identifier: "resizeApp", toggle: true)
    let compact = button("Switch to Compact Window", symbol: "arrow.up.forward.and.arrow.down.backward", identifier: "CompactDeviceWindow")
    let zoom: NSSegmentedControl
    let inspector: NSSegmentedControl
    let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let stack = NSStackView()
    private var overflowPriorities: [ObjectIdentifier: NSStackView.VisibilityPriority] = [:]
    static let inspectorLabels = ["Settings", "Reports", "Info", "Background Services"]
    static let zoomLabels = ["Zoom Out", "Fit", "Physical Size", "Zoom In"]

    override init(frame: NSRect) {
        let zoomSymbols = ["minus.magnifyingglass", "arrowtriangles.up.right.down.left.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"]
        let images = zip(zoomSymbols, Self.zoomLabels).compactMap { NSImage.deviceControlSymbol(named: $0, accessibilityDescription: $1) }
        zoom = images.count == Self.zoomLabels.count
            ? NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
            : NSSegmentedControl(labels: Self.zoomLabels, trackingMode: .selectOne, target: nil, action: nil)
        inspector = NSSegmentedControl(images: zip(["slider.horizontal.3", "text.document", "info", "cpu"], Self.inspectorLabels).map {
            NSImage(systemSymbolName: $0, accessibilityDescription: $1)!
        }, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Device Commands")
        zoom.identifier = .init("CanvasZoom")
        zoom.setAccessibilityLabel("Canvas Zoom")
        inspector.identifier = .init("DeviceInspector")
        inspector.setAccessibilityLabel("Device Inspector")
        inspector.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
        for (control, labels) in [(zoom, Self.zoomLabels), (inspector, Self.inspectorLabels)] {
            control.cell?.isBordered = false
            control.heightAnchor.constraint(equalToConstant: 32).isActive = true
            for (index, label) in labels.enumerated() { control.setToolTip(label, forSegment: index) }
        }
        more.identifier = .init("CanvasMoreActions")
        more.bezelStyle = .inline
        more.isBordered = false
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.imagePosition = .imageOnly
        more.setAccessibilityLabel("More Actions")
        more.toolTip = "More Actions"
        more.menu = NSMenu(title: "Device Actions")
        Self.insertMenuTitle(into: more.menu!)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.setViews([sidebar, settings, filter], in: .leading)
        stack.setViews([captureKeyboard, resizeApp, zoom, compact, more], in: .center)
        stack.setViews([inspector], in: .trailing)
        for (index, control) in [compact, resizeApp, captureKeyboard, settings, filter, inspector, zoom].enumerated() {
            let priority = NSStackView.VisibilityPriority(rawValue: Float(600 + index))
            overflowPriorities[ObjectIdentifier(control)] = priority
            stack.setVisibilityPriority(priority, for: control)
        }
        for control in [sidebar, settings, filter, captureKeyboard, resizeApp, compact, more] {
            control.widthAnchor.constraint(equalToConstant: 32).isActive = true
            control.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    // The stack also hides views while they overflow; command availability must not change that hidden flag.
    func setAvailable(_ available: Bool, for view: NSView) {
        let priority = available ? overflowPriorities[ObjectIdentifier(view)] ?? .mustHold : .notVisible
        if stack.visibilityPriority(for: view) != priority { stack.setVisibilityPriority(priority, for: view) }
    }

    func isOverflowing(_ view: NSView) -> Bool {
        stack.visibilityPriority(for: view) != .notVisible && stack.detachedViews.contains { $0 === view }
    }

    // A pull-down uses its first item as the closed button's label.
    static func insertMenuTitle(into menu: NSMenu) {
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More Actions")
        menu.insertItem(title, at: 0)
    }
}

@MainActor
private func button(_ title: String, symbol: String, identifier: String, toggle: Bool = false) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    button.imagePosition = .imageOnly
    button.bezelStyle = .inline
    button.isBordered = false
    button.identifier = .init(identifier)
    button.toolTip = title
    button.setAccessibilityLabel(title)
    if toggle { button.setButtonType(.pushOnPushOff) }
    return button
}

/// Keeps the split controller's native sizing and autosave behavior below the command bar.
@MainActor
final class ManagerContentViewController: NSViewController {
    init(split: NSSplitViewController, commands: ManagerCommandBar) {
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        addChild(split)
        let content = split.view
        for child in [content, commands] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            commands.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            commands.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            commands.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: commands.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

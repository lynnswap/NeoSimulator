import AppKit
import Observation
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: SimulatorManagerModel
    private let preferences = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer")
    private let hostPopup = NSPopUpButton()
    private let frameworkPopup = NSPopUpButton()
    private let frameworkMessage = NSTextField(wrappingLabelWithString: "")
    private let restartButton = NSButton(title: "Restart to Apply", target: nil, action: nil)
    private let restart: () -> Void
    private let restore = NSButton(title: "Restore Original Settings…", target: nil, action: nil)
    private let gifSize = NSPopUpButton()
    private let gifRate = NSPopUpButton()
    private var toggles: [String: NSButton] = [:]

    init(model: SimulatorManagerModel, restart: @escaping () -> Void) {
        self.model = model
        self.restart = restart
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NeoSimulator Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        preferences?.register(defaults: [
            "StartLastDeviceOnLaunch": true, "SessionOnLaunch": true,
            "DetachOnWindowClose": false, "DetachOnAppQuit": false,
            "ShowSingleTouches": false, "ShowPinches": true, "ScreenShotUseMask": false,
            "GifMaxFrameSize": 640, "GifMaxFramerate": 10,
        ])
        let content = NSView()
        window.contentView = content
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "General")
        general.label = "General"
        general.view = generalPane()
        tabs.addTabViewItem(general)
        let capture = NSTabViewItem(identifier: "Capture")
        capture.label = "Capture"
        capture.view = capturePane()
        tabs.addTabViewItem(capture)
        content.addSubview(tabs)
        restore.bezelStyle = .rounded
        restore.target = self
        restore.action = #selector(restoreDefaults(_:))
        restore.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(restore)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: restore.topAnchor, constant: -14),
            restore.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            restore.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        window.center()
        observeModel()
    }

    required init?(coder: NSCoder) { nil }

    private func observeModel() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }

    func update() {
        updateFrameworkSelection()
        hostPopup.selectItem(at: model.status?.host == .deviceHub ? 1 : 0)
        hostPopup.isEnabled = !model.isBusy && model.status != nil
        restore.isEnabled = !model.isBusy && model.status?.restorationAvailable == true
        for (key, button) in toggles {
            let enabled = preferences?.bool(forKey: key) == true
            let startsSession = key != "StartLastDeviceOnLaunch" || preferences?.bool(forKey: "SessionOnLaunch") == true
            button.state = enabled && startsSession ? .on : .off
            button.isEnabled = preferences != nil
        }
        selectValue(preferences?.integer(forKey: "GifMaxFrameSize"), in: gifSize)
        selectValue(preferences?.integer(forKey: "GifMaxFramerate"), in: gifRate)
        gifSize.isEnabled = preferences != nil
        gifRate.isEnabled = preferences != nil
    }

    private func generalPane() -> NSView {
        hostPopup.addItems(withTitles: ["NeoSimulator", "Device Hub"])
        hostPopup.target = self
        hostPopup.action = #selector(selectHost(_:))
        hostPopup.setAccessibilityLabel("Display Host")
        let stack = formStack()
        stack.addArrangedSubview(popupRow("Display Host:", popup: hostPopup))
        frameworkPopup.target = self
        frameworkPopup.action = #selector(selectFramework(_:))
        frameworkPopup.setAccessibilityLabel("UI Frameworks")
        stack.addArrangedSubview(popupRow("UI Frameworks:", popup: frameworkPopup))
        frameworkMessage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        frameworkMessage.textColor = .secondaryLabelColor
        frameworkMessage.widthAnchor.constraint(equalToConstant: 500).isActive = true
        stack.addArrangedSubview(frameworkMessage)
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartApplication(_:))
        stack.addArrangedSubview(restartButton)
        stack.addArrangedSubview(separator())
        addToggle("Start the last used simulator on launch", key: "StartLastDeviceOnLaunch", to: stack)
        addToggle("Keep simulators running when closing a window", key: "DetachOnWindowClose", to: stack)
        addToggle("Keep simulators running when quitting NeoSimulator", key: "DetachOnAppQuit", to: stack)
        stack.addArrangedSubview(separator())
        addToggle("Show single touches", key: "ShowSingleTouches", to: stack)
        addToggle("Show pinch gestures", key: "ShowPinches", to: stack)
        return pane(containing: stack)
    }

    private func updateFrameworkSelection() {
        let frameworks = model.frameworks
        frameworkPopup.removeAllItems()
        frameworkPopup.addItem(withTitle: "Default (xcode-select)")
        for xcode in frameworks.installations {
            frameworkPopup.addItem(withTitle: "\(xcode.name) (\(xcode.version))")
            frameworkPopup.lastItem?.representedObject = xcode.url
            frameworkPopup.lastItem?.toolTip = xcode.url.path
        }
        if let selected = frameworks.selectedXcodeURL {
            if let item = frameworkPopup.itemArray.first(where: { ($0.representedObject as? URL) == selected }) {
                frameworkPopup.select(item)
            } else {
                frameworkPopup.addItem(withTitle: selected.deletingPathExtension().lastPathComponent)
                frameworkPopup.lastItem?.representedObject = selected
                frameworkPopup.lastItem?.toolTip = selected.path
                frameworkPopup.selectItem(at: frameworkPopup.numberOfItems - 1)
            }
        } else { frameworkPopup.selectItem(at: 0) }
        frameworkPopup.isEnabled = !frameworks.isLoading && !model.isBusy
        frameworkMessage.stringValue = frameworks.issue ?? (frameworks.needsRestart
            ? "Restart NeoSimulator to apply this change. Simulators will keep running."
            : "Uses the selected Xcode's display frameworks. Simulator runtimes are selected independently.")
        restartButton.isHidden = !frameworks.needsRestart
        restartButton.isEnabled = !model.isBusy
    }

    @objc private func selectFramework(_ sender: NSPopUpButton) {
        model.frameworks.select(sender.selectedItem?.representedObject as? URL)
    }

    @objc private func restartApplication(_ sender: Any?) { restart() }

    private func capturePane() -> NSView {
        let stack = formStack()
        addToggle("Include device mask in screenshots and videos", key: "ScreenShotUseMask", to: stack)
        stack.addArrangedSubview(separator())
        for (title, value) in [("Small (320 px)", 320), ("Medium (640 px)", 640), ("Large (1280 px)", 1280)] {
            gifSize.addItem(withTitle: title)
            gifSize.lastItem?.tag = value
        }
        gifSize.target = self
        gifSize.action = #selector(changeGifSize(_:))
        gifSize.setAccessibilityLabel("GIF Image Size")
        for (title, value) in [("For smaller file size", 10), ("For smoother animation", 15)] {
            gifRate.addItem(withTitle: title)
            gifRate.lastItem?.tag = value
        }
        gifRate.target = self
        gifRate.action = #selector(changeGifRate(_:))
        gifRate.setAccessibilityLabel("Optimize GIFs")
        stack.addArrangedSubview(popupRow("GIF Image Size:", popup: gifSize))
        stack.addArrangedSubview(popupRow("Optimize GIFs:", popup: gifRate))
        return pane(containing: stack)
    }

    private func formStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func pane(containing stack: NSStackView) -> NSView {
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        return view
    }

    private func popupRow(_ title: String, popup: NSPopUpButton) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }

    private func addToggle(_ title: String, key: String, to stack: NSStackView) {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(togglePreference(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        toggles[key] = button
        stack.addArrangedSubview(button)
    }

    private func selectValue(_ value: Int?, in popup: NSPopUpButton) {
        if let value, let item = popup.itemArray.first(where: { $0.tag == value }) { popup.select(item) }
        else { popup.selectItem(at: -1) }
    }

    private func save(_ value: Any, for key: String) {
        guard let preferences else { return }
        preferences.set(value, forKey: key)
        if key == "StartLastDeviceOnLaunch" { preferences.set(value, forKey: "SessionOnLaunch") }
        if !preferences.synchronize() {
            let alert = NSAlert()
            alert.messageText = "The simulator setting could not be saved."
            alert.informativeText = "Try changing the setting again."
            if let window { alert.beginSheetModal(for: window) }
        }
        update()
    }

    @objc private func togglePreference(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        save(sender.state == .on, for: key)
    }

    @objc private func changeGifSize(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.tag else { return }
        save(value, for: "GifMaxFrameSize")
    }

    @objc private func changeGifRate(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.tag else { return }
        save(value, for: "GifMaxFramerate")
    }

    @objc private func selectHost(_ sender: NSPopUpButton) { model.select(sender.indexOfSelectedItem == 1 ? .deviceHub : .neo) }

    @objc private func restoreDefaults(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Restore original settings?"
        alert.informativeText = "Restore the routing settings saved before NeoSimulator first changed them. Your simulator devices are kept."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.restoreDefaults() }
        }
    }
}

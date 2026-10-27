import AppKit

/// Creates devices from compatible type/runtime pairs, optionally pairing an iPhone and watch.
/// Creation does not boot them. Partial failures retain created devices and name them in the alert.
@MainActor
final class NewSimulatorWindowController: NSWindowController, NSWindowDelegate {
    struct ExistingDevice {
        let identifier: String
        let name: String
        let productFamily: String
        let deviceType: String
        let runtime: String
    }

    private struct CreationFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Creates a device and returns its identifier.
    typealias Create = @MainActor (_ name: String, _ deviceType: String, _ runtime: String) async throws -> String
    typealias Pair = @MainActor (_ watch: String, _ phone: String) async throws -> Void

    let nameField = NSTextField()
    let deviceTypes = NSPopUpButton()
    let runtimes = NSPopUpButton()
    let pairedWatchButton = NSButton(checkboxWithTitle: "Paired Apple Watch", target: nil, action: nil)
    let watchNameField = NSTextField()
    let watchDeviceTypes = NSPopUpButton()
    let watchRuntimes = NSPopUpButton()
    let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    /// Create, or Next while the first page leads to the watch's page.
    let forwardButton = NSButton(title: "Create", target: nil, action: nil)
    private let simulatorPage = NSGridView()
    private let watchPage = NSGridView()
    private let catalog: SimulatorCatalog
    private let existingDevice: ExistingDevice?
    private let create: Create
    private let pair: Pair
    private let onClose: () -> Void
    private var creation: Task<Void, Never>?
    private var createsPhone: Bool { existingDevice?.productFamily == "Apple Watch" }

    init(catalog: SimulatorCatalog, pairingWith existingDevice: ExistingDevice? = nil,
         create: @escaping Create, pair: @escaping Pair, onClose: @escaping () -> Void = {}) {
        self.catalog = catalog
        self.existingDevice = existingDevice
        self.create = create
        self.pair = pair
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 196, y: 240, width: 618, height: 258),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = existingDevice.map { $0.productFamily == "Apple Watch" ? "New iPhone Simulator" : "New Watch Simulator" }
            ?? "New Simulator"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        fillMenus()
        if !createsPhone { fillWatchMenus() }
        if existingDevice != nil {
            previousButton.isHidden = true
            pairedWatchButton.isHidden = true
            showWatchPage(!createsPhone)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Whether the watch's page is showing.
    var showsWatchPage: Bool { !watchPage.isHidden }

    private func makeContent() -> NSView {
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            return label
        }
        func layOut(_ page: NSGridView, _ rows: [[NSView]]) {
            for row in rows { page.addRow(with: row) }
            page.column(at: 0).xPlacement = .trailing
            page.rowAlignment = .firstBaseline
            page.rowSpacing = 8
        }
        for field in [nameField, watchNameField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        for (popUp, action) in [(deviceTypes, #selector(deviceTypeChanged(_:))), (runtimes, #selector(runtimeChanged(_:))),
                                (watchDeviceTypes, #selector(watchDeviceTypeChanged(_:))),
                                (watchRuntimes, #selector(watchRuntimeChanged(_:)))] {
            popUp.target = self
            popUp.action = action
        }
        pairedWatchButton.target = self
        pairedWatchButton.action = #selector(pairedWatchChanged(_:))
        if createsPhone {
            layOut(simulatorPage, [
                [label("Name:"), nameField],
                [label("OS Version:"), runtimes],
                [label("Model:"), deviceTypes],
            ])
        } else {
            layOut(simulatorPage, [
                [label("Simulator Name:"), nameField],
                [label("Device Type:"), deviceTypes],
                [label("OS Version:"), runtimes],
                [NSGridCell.emptyContentView, pairedWatchButton],
            ])
        }
        layOut(watchPage, [
            [label("Paired Watch Name:"), watchNameField],
            [label("Device Type:"), watchDeviceTypes],
            [label("OS Version:"), watchRuntimes],
        ])
        watchPage.isHidden = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        previousButton.target = self
        previousButton.action = #selector(previous(_:))
        previousButton.isEnabled = false
        forwardButton.target = self
        forwardButton.action = #selector(forward(_:))
        let heading = NSTextField(labelWithString: existingDevice.map { "Create \(createsPhone ? "an iPhone" : "an Apple Watch") for \($0.name):" }
                                  ?? "Create a new simulator:")
        let content = NSView()
        for view in [heading, simulatorPage, watchPage, cancel, previousButton, forwardButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            simulatorPage.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            simulatorPage.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            watchPage.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            watchPage.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            cancel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            previousButton.trailingAnchor.constraint(equalTo: forwardButton.leadingAnchor, constant: -12),
            previousButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            forwardButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            forwardButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func fillMenus() {
        let types = catalog.deviceTypes.filter { type in
            !createsPhone || (type.productFamily == 1 && catalog.runtimes.contains {
                phoneRuntime($0.identifier, supports: type.identifier)
            })
        }
        var family: Int?
        for type in types {
            if let family, family != type.productFamily { deviceTypes.menu?.addItem(.separator()) }
            family = type.productFamily
            deviceTypes.menu?.addItem(item(type.name, representing: type.identifier))
        }
        let availableRuntimes = catalog.runtimes.filter { runtime in
            !createsPhone || types.contains { phoneRuntime(runtime.identifier, supports: $0.identifier) }
        }
        guard !availableRuntimes.isEmpty else {
            addNoRuntimesItem(to: runtimes)
            for control in [runtimes, deviceTypes, pairedWatchButton] as [NSControl] { control.isEnabled = false }
            updateForwardButton()
            return
        }
        for runtime in availableRuntimes {
            runtimes.menu?.addItem(item(runtime.name, representing: runtime.identifier))
        }
        deviceTypes.selectItem(at: 0)
        runtimes.selectItem(at: 0)
        // Keep the initial runtime and select a compatible device type.
        runtimeChanged(nil)
    }

    /// The watch's page lists the watch device types without separators and,
    /// at first, the runtimes that support any of them.
    private func fillWatchMenus() {
        let watchTypes = catalog.deviceTypes.filter { type in
            type.productFamily == 4 && (existingDevice == nil || catalog.runtimes.contains {
                watchRuntime($0.identifier, supports: type.identifier)
            })
        }
        for type in watchTypes { watchDeviceTypes.menu?.addItem(item(type.name, representing: type.identifier)) }
        let runtimes = catalog.runtimes.filter { runtime in
            watchTypes.contains { watchRuntime(runtime.identifier, supports: $0.identifier) }
        }
        guard !runtimes.isEmpty else {
            addNoRuntimesItem(to: watchRuntimes)
            watchRuntimes.isEnabled = false
            watchDeviceTypes.isEnabled = false
            return
        }
        for runtime in runtimes { watchRuntimes.menu?.addItem(item(runtime.name, representing: runtime.identifier)) }
        watchDeviceTypes.selectItem(at: 0)
        watchRuntimes.selectItem(at: 0)
        watchRuntimeChanged(nil)
    }

    private func addNoRuntimesItem(to popUp: NSPopUpButton) {
        let none = NSMenuItem(title: "No Runtimes Available", action: nil, keyEquivalent: "")
        none.isEnabled = false
        popUp.menu?.addItem(none)
    }

    private func item(_ title: String, representing identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = identifier
        return item
    }

    private var deviceType: String? { deviceTypes.selectedItem?.representedObject as? String }
    private var runtime: String? { runtimes.selectedItem?.representedObject as? String }
    private var watchType: String? { watchDeviceTypes.selectedItem?.representedObject as? String }
    private var watchRuntime: String? { watchRuntimes.selectedItem?.representedObject as? String }

    private func phoneRuntime(_ runtime: String, supports type: String) -> Bool {
        guard catalog.runtime(runtime, supports: type) else { return false }
        guard let existingDevice, createsPhone else { return true }
        return catalog.canPair(existingDevice.deviceType, existingDevice.runtime, type, runtime)
    }

    private func watchRuntime(_ runtime: String, supports type: String) -> Bool {
        guard catalog.runtime(runtime, supports: type) else { return false }
        guard let existingDevice, !createsPhone else { return true }
        return catalog.canPair(type, runtime, existingDevice.deviceType, existingDevice.runtime)
    }

    // An empty selection is incompatible so the next change restores a valid pair.
    @objc private func deviceTypeChanged(_ sender: Any?) {
        if let deviceType, runtime.map({ phoneRuntime($0, supports: deviceType) }) != true {
            select(in: runtimes) { phoneRuntime($0, supports: deviceType) }
        }
        simulatorSelectionDidChange()
    }

    @objc private func runtimeChanged(_ sender: Any?) {
        if let runtime, deviceType.map({ phoneRuntime(runtime, supports: $0) }) != true {
            select(in: deviceTypes) { phoneRuntime(runtime, supports: $0) }
        }
        simulatorSelectionDidChange()
    }

    /// Only a new iPhone can add a watch through the second page; an empty selection preserves the current state.
    private func simulatorSelectionDidChange() {
        nameField.placeholderString = deviceTypes.selectedItem?.title
        if let family = deviceType.flatMap(catalog.deviceType)?.productFamily {
            pairedWatchButton.isEnabled = existingDevice == nil && family == 1
            if !pairedWatchButton.isEnabled { pairedWatchButton.state = .off }
        }
        updateForwardButton()
    }

    /// Rebuilds the runtime list when the selected watch requires a different runtime.
    @objc private func watchDeviceTypeChanged(_ sender: Any?) {
        if let watchType, watchRuntime.map({ self.watchRuntime($0, supports: watchType) }) != true {
            watchRuntimes.removeAllItems()
            for runtime in catalog.runtimes where self.watchRuntime(runtime.identifier, supports: watchType) {
                watchRuntimes.menu?.addItem(item(runtime.name, representing: runtime.identifier))
            }
            watchRuntimes.select(watchRuntimes.itemArray.first)
        }
        watchNameField.placeholderString = watchDeviceTypes.selectedItem?.title
        updateForwardButton()
    }

    @objc private func watchRuntimeChanged(_ sender: Any?) {
        if let watchRuntime, watchType.map({ self.watchRuntime(watchRuntime, supports: $0) }) != true {
            select(in: watchDeviceTypes) { self.watchRuntime(watchRuntime, supports: $0) }
        }
        watchNameField.placeholderString = watchDeviceTypes.selectedItem?.title
        updateForwardButton()
    }

    /// Selects the first item whose identifier matches, or nothing.
    private func select(in popUp: NSPopUpButton, where matches: (String) -> Bool) {
        popUp.select(popUp.itemArray.first { ($0.representedObject as? String).map(matches) == true })
    }

    @objc private func pairedWatchChanged(_ sender: Any?) { updateForwardButton() }

    private var pairsWatch: Bool {
        (existingDevice != nil && !createsPhone) || (pairedWatchButton.isEnabled && pairedWatchButton.state == .on)
    }

    /// Whether the four choices make a pair that CoreSimulator can create.
    private var canPair: Bool {
        guard let deviceType = createsPhone ? deviceType : existingDevice?.deviceType ?? deviceType,
              let runtime = createsPhone ? runtime : existingDevice?.runtime ?? runtime,
              let watchType = createsPhone ? existingDevice?.deviceType : watchType,
              let watchRuntime = createsPhone ? existingDevice?.runtime : watchRuntime,
              catalog.runtime(watchRuntime, supports: watchType) else { return false }
        return catalog.canPair(watchType, watchRuntime, deviceType, runtime)
    }

    private func updateForwardButton() {
        forwardButton.title = pairsWatch && !showsWatchPage ? "Next" : "Create"
        forwardButton.isEnabled = !catalog.runtimes.isEmpty && creation == nil &&
            ((existingDevice == nil && !showsWatchPage) || canPair)
    }

    private func showWatchPage(_ shows: Bool) {
        simulatorPage.isHidden = shows
        watchPage.isHidden = !shows
        previousButton.isEnabled = shows && existingDevice == nil
        updateForwardButton()
    }

    @objc private func forward(_ sender: Any?) {
        if pairsWatch && !showsWatchPage { showWatchPage(true) } else { createSimulator() }
    }

    @objc private func previous(_ sender: Any?) { showWatchPage(false) }

    /// An empty name field names the device after its placeholder.
    private static func name(in field: NSTextField) -> String {
        field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue
    }

    private func createSimulator() {
        guard creation == nil, (existingDevice == nil && !pairsWatch) || canPair else { return }
        let newDevice: (name: String, deviceType: String, runtime: String)
        if existingDevice != nil, !createsPhone {
            guard let watchType, let watchRuntime else { return }
            newDevice = (Self.name(in: watchNameField), watchType, watchRuntime)
        } else {
            guard let deviceType, let runtime else { return }
            newDevice = (Self.name(in: nameField), deviceType, runtime)
        }
        var watch: (name: String, deviceType: String, runtime: String)?
        if existingDevice == nil, pairsWatch {
            guard let watchType, let watchRuntime else { return }
            watch = (Self.name(in: watchNameField), watchType, watchRuntime)
        }
        creation = Task {
            defer {
                creation = nil
                updateForwardButton()
            }
            do {
                let identifier = try await create(newDevice.name, newDevice.deviceType, newDevice.runtime)
                if let existingDevice {
                    do {
                        if createsPhone { try await pair(existingDevice.identifier, identifier) }
                        else { try await pair(identifier, existingDevice.identifier) }
                    } catch {
                        throw CreationFailure(
                            "Created “\(newDevice.name)” (\(identifier)), but could not pair it with “\(existingDevice.name)”: \(error.localizedDescription)")
                    }
                } else if let watch {
                    let watchIdentifier: String
                    do { watchIdentifier = try await create(watch.name, watch.deviceType, watch.runtime) } catch {
                        throw CreationFailure(
                            "Created “\(newDevice.name)”, but could not create its paired Apple Watch: \(error.localizedDescription)")
                    }
                    do { try await pair(watchIdentifier, identifier) } catch {
                        throw CreationFailure(
                            "Created “\(newDevice.name)” and “\(watch.name)”, but could not pair them: \(error.localizedDescription)")
                    }
                }
                close()
            } catch {
                // The window may have been closed while the devices were being created.
                if let window, window.isVisible {
                    NSAlert(presenting: error).beginSheetModal(for: window, completionHandler: nil)
                } else {
                    NSAlert(presenting: error).runModal()
                }
            }
        }
        updateForwardButton()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) { onClose() }
}

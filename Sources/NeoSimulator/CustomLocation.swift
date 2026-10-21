import AppKit

/// Features ▸ Location ▸ Custom Location…: Simulator.app's window that asks
/// for a coordinate, an ordinary window rather than a sheet. Each device window
/// has its own. OK is enabled only while both fields parse.
@MainActor
final class CustomLocationWindowController: NSWindowController, NSTextFieldDelegate {
    let latitudeField = NSTextField()
    let longitudeField = NSTextField()
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let latitudeFormatter = CustomLocationWindowController.formatter(limit: 90)
    private let longitudeFormatter = CustomLocationWindowController.formatter(limit: 180)
    private let onOK: (_ latitude: Double, _ longitude: Double) -> Void

    init(onOK: @escaping (_ latitude: Double, _ longitude: Double) -> Void) {
        self.onOK = onOK
        // Like Simulator.app's, the window has no close, minimize, or zoom
        // button; Cancel closes it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 188), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Custom Location"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        latitudeField.formatter = latitudeFormatter
        longitudeField.formatter = longitudeFormatter
        window.contentView = makeContent()
        window.initialFirstResponder = latitudeField
    }

    required init?(coder: NSCoder) { nil }

    /// Simulator.app's coordinate format: decimal numbers in the current
    /// locale, with up to six fraction digits, no grouping, and at most `limit`
    /// in either direction.
    static func formatter(limit: Double) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.minimumIntegerDigits = 1
        formatter.usesGroupingSeparator = false
        formatter.isLenient = false
        formatter.minimum = NSNumber(value: -limit)
        formatter.maximum = NSNumber(value: limit)
        return formatter
    }

    /// Shows the window with the saved coordinate.
    func show(latitude: Double, longitude: Double) {
        latitudeField.doubleValue = latitude
        longitudeField.doubleValue = longitude
        updateOK()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    private func makeContent() -> NSView {
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            return label
        }
        let message = NSTextField(
            wrappingLabelWithString: "Enter a latitude and longitude for the location you would like to simulate.")
        message.preferredMaxLayoutWidth = 350
        for field in [latitudeField, longitudeField] {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }
        let grid = NSGridView(views: [[label("Latitude:"), latitudeField], [label("Longitude:"), longitudeField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        okButton.target = self
        okButton.action = #selector(confirm(_:))
        okButton.keyEquivalent = "\r"
        let content = NSView()
        for view in [message, grid, cancel, okButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 390),
            message.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 16),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            okButton.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            okButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            okButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            okButton.widthAnchor.constraint(equalTo: cancel.widthAnchor),
            cancel.trailingAnchor.constraint(equalTo: okButton.leadingAnchor, constant: -12),
            cancel.firstBaselineAnchor.constraint(equalTo: okButton.firstBaselineAnchor),
        ])
        return content
    }

    func controlTextDidChange(_ notification: Notification) { updateOK() }

    private func updateOK() { okButton.isEnabled = coordinate != nil }

    // Reads the text being typed from the field editor: while a field is
    // edited, `stringValue` runs it through the formatter and erases text that
    // does not parse. Simulator.app detaches the formatters to read it.
    private var coordinate: (latitude: Double, longitude: Double)? {
        func value(_ field: NSTextField, _ formatter: NumberFormatter) -> Double? {
            formatter.number(from: field.currentEditor()?.string ?? field.stringValue)?.doubleValue
        }
        guard let latitude = value(latitudeField, latitudeFormatter),
              let longitude = value(longitudeField, longitudeFormatter) else { return nil }
        return (latitude, longitude)
    }

    @objc private func confirm(_ sender: Any?) {
        guard let coordinate else { return }
        close()
        onOK(coordinate.latitude, coordinate.longitude)
    }

    @objc private func cancel(_ sender: Any?) { close() }
}

import AppKit
import NeoSimulatorKit

/// What a device's optional services tell the person using its screen, if anything. A pasteboard that has not connected
/// yet costs nothing until a transfer waits for it, so only its failure and a wait for the device's record show.
package struct DeviceServiceStatus: Equatable {
    package var message: String
    package var offersRetry: Bool

    package init?(input: SimulatorServiceReadiness, pasteboard: SimulatorServiceReadiness, isAwaitingDeviceRecord: Bool = false) {
        if let failure = input.failure {
            message = "The device's keyboard and touch input aren't connected: \(failure.localizedDescription)"
            offersRetry = true
        } else if let failure = pasteboard.failure {
            message = "The device's pasteboard isn't connected: \(failure.localizedDescription)"
            offersRetry = false
        } else if isAwaitingDeviceRecord {
            message = "Waiting for CoreDevice to report this device…"
            offersRetry = false
        } else if case .pending = input {
            message = "Connecting the device's keyboard and touch input…"
            offersRetry = false
        } else {
            return nil
        }
    }
}

/// States a device's service status in front of its screen. It never changes the screen's geometry, and only Retry takes
/// events, so the screen beneath keeps its input.
@MainActor
final class DeviceServiceStatusView: NSVisualEffectView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let onRetry: () -> Void

    init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        retry.controlSize = .small
        retry.target = self
        retry.action = #selector(retryPressed)
        let stack = NSStackView(views: [label, retry])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ status: DeviceServiceStatus) {
        label.stringValue = status.message
        retry.isHidden = !status.offersRetry
    }

    /// The size this takes in a space `width` wide.
    func size(fitting width: CGFloat) -> NSSize {
        label.preferredMaxLayoutWidth = max(0, width - 20 - (retry.isHidden ? 0 : retry.intrinsicContentSize.width + 8))
        let fitting = fittingSize
        return NSSize(width: min(fitting.width, width), height: fitting.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit.isDescendant(of: retry) else { return nil }
        return hit
    }

    @objc private func retryPressed() { onRetry() }
}

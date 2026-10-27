import AppKit
import SwiftUI

@MainActor
final class SimulatorSidebarCellView: NSTableCellView {
    private let labels = NSHostingView(rootView: SidebarDeviceLabels(name: "", subtitle: ""))
    let version = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private var artworkHost: NSHostingView<SidebarDeviceArtwork>?

    func setLabels(name: String, subtitle: String) {
        labels.rootView = SidebarDeviceLabels(name: name, subtitle: subtitle)
    }

    func setArtwork(_ model: DeviceArtworkModel, isActive: Bool) {
        let content = SidebarDeviceArtwork(model: model, isActive: isActive, isEmphasized: backgroundStyle == .emphasized)
        if let artworkHost { artworkHost.rootView = content }
        else {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.setAccessibilityHidden(true)
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                host.centerYAnchor.constraint(equalTo: centerYAnchor),
                host.widthAnchor.constraint(equalToConstant: 32),
                host.heightAnchor.constraint(equalToConstant: 32),
            ])
            artworkHost = host
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard let artworkHost else { return }
            let previous = artworkHost.rootView
            artworkHost.rootView = SidebarDeviceArtwork(model: previous.model, isActive: previous.isActive,
                                                        isEmphasized: backgroundStyle == .emphasized)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .right
        version.translatesAutoresizingMaskIntoConstraints = false
        version.setContentCompressionResistancePriority(.required, for: .horizontal)
        version.setContentHuggingPriority(.required, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        let trailing = NSStackView(views: [progress, version])
        trailing.distribution = .fill
        trailing.spacing = 6
        trailing.translatesAutoresizingMaskIntoConstraints = false
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 49),
            labels.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }


}

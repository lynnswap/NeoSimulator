import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import SwiftUI
import NeoSimulatorPresentationAdapters
import NeoSimulatorDeviceScreens

@MainActor
final class SimulatorSidebarCellView: NSTableCellView {
    private let labels = NSHostingView(rootView: SidebarDeviceLabels(name: "", subtitle: ""))
    let version = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private var artworkHost: NSHostingView<SidebarDeviceArtwork>?
    private let thumbnail = DeviceThumbnailView()
    private var showsThumbnail = false

    func setThumbnail(_ frame: DeviceThumbnailFrame?, image: CGImage?, animated: Bool = true) {
        thumbnail.setFrame(frame, image: image, animated: animated)
        let shown = frame != nil || image != nil
        if !animated {
            thumbnail.layer?.removeAllAnimations()
            showsThumbnail = shown
            thumbnail.alphaValue = shown ? 1 : 0
            updateArtworkSymbol(animated: false)
            return
        }
        guard shown != showsThumbnail else { return }
        showsThumbnail = shown
        thumbnail.isHidden = false
        updateArtworkSymbol(animated: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            thumbnail.animator().alphaValue = shown ? 1 : 0
        }
    }

    private func updateArtworkSymbol(animated: Bool) {
        guard let artworkHost else { return }
        var content = artworkHost.rootView
        content.showsSymbol = !showsThumbnail
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0
        withAnimation(.easeInOut(duration: duration)) { artworkHost.rootView = content }
    }

    func setLabels(name: String, subtitle: String) {
        labels.rootView = SidebarDeviceLabels(name: name, subtitle: subtitle)
    }

    func setArtwork(_ model: DeviceArtworkModel, isActive: Bool) {
        let content = SidebarDeviceArtwork(model: model, isActive: isActive, isEmphasized: backgroundStyle == .emphasized,
                                           showsSymbol: !showsThumbnail)
        if let artworkHost { artworkHost.rootView = content }
        else {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.setAccessibilityHidden(true)
            addSubview(host, positioned: .below, relativeTo: thumbnail)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
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
                                                        isEmphasized: backgroundStyle == .emphasized, showsSymbol: !showsThumbnail)
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
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.isHidden = true
        thumbnail.alphaValue = 0
        addSubview(thumbnail)
        addSubview(labels)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 32),
            thumbnail.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 41),
            labels.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }


}

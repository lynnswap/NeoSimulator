import AppKit
import NeoSimulatorPresentationAdapters

/// The shared framebuffer and device outline, above the row's existing artwork background.
@MainActor
final class DeviceThumbnailView: NSView {
    private let device = CALayer()
    private let bezel = CALayer()
    private let screen = CALayer()
    private let screenMask = CALayer()
    private var chrome: DeviceThumbnailChrome?
    private var pixelSize = CGSize.zero
    private var rotation: CGFloat = 0
    private var displayedFrame: DeviceThumbnailFrame?
    private var displayedImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        screen.backgroundColor = NSColor.black.cgColor
        screen.masksToBounds = true
        screen.contentsGravity = .resize
        screenMask.contentsGravity = .resize
        layer?.addSublayer(device)
        device.addSublayer(bezel)
        device.addSublayer(screen)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setFrame(_ frame: DeviceThumbnailFrame?, image: CGImage?, animated: Bool = true) {
        if !animated { screen.removeAllAnimations() }
        guard frame != displayedFrame || image !== displayedImage else { return }
        let previousSize = pixelSize
        let previousRotation = rotation
        let previousChrome = chrome
        if animated, screen.contents != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            screen.add(transition, forKey: "thumbnailFade")
        }
        displayedFrame = frame
        displayedImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // IOSurface storage is reused in place; assigning the same object alone may not dirty the layer.
        screen.contents = nil
        if let frame {
            screen.contents = frame.surface
            chrome = frame.chrome
            pixelSize = chrome?.size ?? frame.size
            rotation = frame.rotation
        } else if let image {
            screen.contents = image
            chrome = nil
            pixelSize = CGSize(width: image.width, height: image.height)
            rotation = 0
        } else {
            screen.contents = nil
            chrome = nil
            pixelSize = .zero
        }
        bezel.contents = chrome?.image
        screenMask.contents = chrome?.mask
        screen.mask = chrome?.mask == nil ? nil : screenMask
        CATransaction.commit()
        if pixelSize != previousSize || rotation != previousRotation || previousChrome !== chrome { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard pixelSize.width > 0, pixelSize.height > 0, bounds.width > 4, bounds.height > 4 else { return }
        let rotated = CGRect(origin: .zero, size: pixelSize).applying(CGAffineTransform(rotationAngle: rotation)).size
        let scale = min((bounds.width - 4) / rotated.width, (bounds.height - 4) / rotated.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        device.bounds = CGRect(origin: .zero, size: CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale))
        device.position = CGPoint(x: bounds.midX, y: bounds.midY)
        device.setAffineTransform(CGAffineTransform(rotationAngle: rotation))
        bezel.frame = device.bounds
        screen.frame = chrome?.displayRect.applying(CGAffineTransform(scaleX: scale, y: scale)) ?? device.bounds
        screen.cornerRadius = chrome?.mask == nil ? (chrome?.cornerRadius ?? 0) * scale : 0
        screenMask.frame = screen.bounds
        CATransaction.commit()
    }

}

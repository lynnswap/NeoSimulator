import AppKit
import QuartzCore

@MainActor
final class DisplayPresentationView: NSView {
    struct Snapshot {
        let modelSize: NSSize
        let centerInScreen: NSPoint
        let scale: CGFloat
        let angle: CGFloat
    }

    private var display: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func setDisplay(_ view: NSView) {
        layer?.removeAllAnimations()
        display?.removeFromSuperview()
        display = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    func setDisplayFrame(_ frame: NSRect) {
        self.frame = frame
        display?.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.removeAnimation(forKey: "displayRotation")
    }

    var snapshot: Snapshot? {
        guard let window, window.isVisible, let layer, let superview else { return nil }
        let model = convert(bounds, to: nil)
        let shown = layer.animation(forKey: "displayRotation") == nil ? layer : layer.presentation() ?? layer
        let frame = window.convertToScreen(superview.convert(shown.frame, to: nil))
        let transform = shown.affineTransform()
        return Snapshot(modelSize: model.size, centerInScreen: NSPoint(x: frame.midX, y: frame.midY),
                        scale: hypot(transform.a, transform.b), angle: atan2(transform.b, transform.a))
    }

    func animateRotation(from previous: Snapshot?, by degrees: Double) {
        guard let previous, let layer, let window, window.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        var rotation = degrees.truncatingRemainder(dividingBy: 360)
        if rotation > 180 { rotation -= 360 }
        if rotation < -180 { rotation += 360 }
        guard rotation != 0 else { return }
        let target = convert(bounds, to: nil)
        let rotatedWidth = abs(rotation.truncatingRemainder(dividingBy: 180)) == 90 ? target.height : target.width
        guard rotatedWidth > 0 else { return }
        let scale = previous.modelSize.width / rotatedWidth * previous.scale
        let angle = previous.angle - CGFloat(rotation) * .pi / 180
        let previousCenter = convert(window.convertPoint(fromScreen: previous.centerInScreen), from: nil)
        let offset = NSPoint(x: previousCenter.x - bounds.midX, y: previousCenter.y - bounds.midY)
        let pivot = NSPoint(x: (0.5 - layer.anchorPoint.x) * bounds.width,
                            y: (0.5 - layer.anchorPoint.y) * bounds.height)
        let steps = max(2, Int(ceil(abs(angle) / (.pi / 20))))
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = (0...steps).map { step in
            let remaining = 1 - CGFloat(step) / CGFloat(steps)
            let currentScale = 1 + (scale - 1) * remaining
            let transform = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                .concatenating(CGAffineTransform(rotationAngle: angle * remaining))
                .concatenating(CGAffineTransform(scaleX: currentScale, y: currentScale))
                .concatenating(CGAffineTransform(translationX: pivot.x + offset.x * remaining,
                                               y: pivot.y + offset.y * remaining))
            return NSValue(caTransform3D: CATransform3DMakeAffineTransform(transform))
        }
        animation.duration = NSAnimationContext.current.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "displayRotation")
    }
}

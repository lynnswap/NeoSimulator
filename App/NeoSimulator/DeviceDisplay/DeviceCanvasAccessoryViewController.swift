import AppKit

@MainActor
final class DeviceCanvasAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let controlsStack = NSStackView()
    var onMinimumWidthChange: ((CGFloat) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        controlsStack.orientation = .vertical
        controlsStack.alignment = .centerX
        controlsStack.frame.size = NSSize(width: 320, height: 36)
        view = controlsStack
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func setControls(_ controls: DeviceCanvasControls?) {
        if controlsStack.arrangedSubviews.first !== controls || controls.map({ $0.superview !== controlsStack }) == true {
            for child in controlsStack.arrangedSubviews {
                controlsStack.removeArrangedSubview(child)
                if child.superview === controlsStack { child.removeFromSuperview() }
            }
            if let controls {
                controls.removeFromSuperview()
                controlsStack.addArrangedSubview(controls)
            }
        }
        isHidden = controls?.isHidden != false
        updateMinimumWidth()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMinimumWidth()
    }

    private func updateMinimumWidth() {
        let controls = controlsStack.arrangedSubviews.first
        onMinimumWidthChange?(controls.flatMap { $0.isHidden ? nil : $0.fittingSize.width + 24 } ?? 0)
    }
}

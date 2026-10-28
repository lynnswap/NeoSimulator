import AppKit

@MainActor
final class DeviceCanvasAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let controlsStack = NSStackView()
    var onMinimumWidthChange: ((CGFloat) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        controlsStack.orientation = .vertical
        controlsStack.alignment = .centerX
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
        refresh()
    }

    func refresh() {
        let controls = controlsStack.arrangedSubviews.first { $0.superview === controlsStack }
        isHidden = controls?.isHidden != false
        onMinimumWidthChange?(controls.flatMap { $0.isHidden ? nil : $0.fittingSize.width + 24 } ?? 0)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        refresh()
    }
}

import AppKit
import SwiftUI

@MainActor
struct ManagerSettingSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let tickMarks: Int
    let label: String
    let changed: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.isContinuous = false
        slider.controlSize = .regular
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.change(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.changed = changed
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.numberOfTickMarks = tickMarks
        slider.allowsTickMarkValuesOnly = tickMarks > 0
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(label)
    }

    @MainActor final class Coordinator: NSObject {
        var changed: (Double) -> Void
        init(changed: @escaping (Double) -> Void) { self.changed = changed }
        @objc func change(_ sender: NSSlider) { changed(sender.doubleValue) }
    }
}

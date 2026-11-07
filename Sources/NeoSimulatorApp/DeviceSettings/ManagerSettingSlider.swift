import AppKit
import NeoSimulatorHostSupport
import NeoSimulatorKit
import SwiftUI

@MainActor
struct ManagerSettingSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickMarks: Int
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.isContinuous = false
        slider.controlSize = .regular
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.change(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.numberOfTickMarks = tickMarks
        slider.allowsTickMarkValuesOnly = tickMarks > 0
        slider.isEnabled = context.environment.isEnabled
        slider.setAccessibilityLabel(label)
    }

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func change(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

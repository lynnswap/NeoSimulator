import AppKit
import Foundation
import ObservationBridge
import SwiftUI

@MainActor
struct ManagerSettingSlider: NSViewRepresentable {
    let model: DeviceSettingSliderModel

    func makeNSView(context: Context) -> Control { Control(model: model) }
    func updateNSView(_ slider: Control, context: Context) {
        slider.setModel(model)
        slider.controlsEnabled = context.environment.isEnabled
    }
    static func dismantleNSView(_ slider: Control, coordinator: ()) { slider.stopObserving() }

    @MainActor final class Control: NSSlider {
        private(set) var model: DeviceSettingSliderModel
        private var observation: PortableObservationTracking.Token?
        var controlsEnabled = true { didSet { if controlsEnabled != oldValue { refresh() } } }

        init(model: DeviceSettingSliderModel) {
            self.model = model
            super.init(frame: .zero)
            isContinuous = false
            controlSize = .regular
            target = self
            action = #selector(change)
            observeModel()
        }

        required init?(coder: NSCoder) { nil }

        func setModel(_ model: DeviceSettingSliderModel) {
            guard self.model !== model else { return }
            stopObserving()
            self.model = model
            observeModel()
        }

        private func observeModel() {
            minValue = model.range.lowerBound
            maxValue = model.range.upperBound
            numberOfTickMarks = model.tickMarks
            allowsTickMarkValuesOnly = model.tickMarks > 0
            setAccessibilityLabel(String(localized: model.label))
            refresh()
            observation = withPortableContinuousObservation { [weak self] _ in self?.refresh() }
        }

        func stopObserving() {
            observation?.cancel()
            observation = nil
            isEnabled = false
        }

        private func refresh() {
            doubleValue = model.value
            isEnabled = controlsEnabled && model.isEnabled
            toolTip = model.help
        }

        @objc private func change() {
            guard isEnabled && model.isEnabled else {
                doubleValue = model.value
                return
            }
            model.value = doubleValue
        }

        isolated deinit { observation?.cancel() }
    }
}

import Foundation
import NeoSimulatorDeviceIO

/// A guest's light or dark appearance.
public enum DeviceAppearance: String, CaseIterable, Sendable {
    /// Light appearance.
    case light
    /// Dark appearance.
    case dark
}

/// The guest's preferred text size, smallest first. Raw values are `devicectl`'s.
public enum DeviceContentSize: String, CaseIterable, Sendable {
    /// Extra small.
    case extraSmall = "extra-small"
    /// Small.
    case small
    /// Medium.
    case medium
    /// Large.
    case large
    /// Extra large.
    case extraLarge = "extra-large"
    /// Extra extra large.
    case extraExtraLarge = "extra-extra-large"
    /// Extra extra extra large.
    case extraExtraExtraLarge = "extra-extra-extra-large"
    /// Accessibility medium.
    case accessibilityMedium = "accessibility-medium"
    /// Accessibility large.
    case accessibilityLarge = "accessibility-large"
    /// Accessibility extra large.
    case accessibilityExtraLarge = "accessibility-extra-large"
    /// Accessibility extra extra large.
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    /// Accessibility extra extra extra large.
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"
}

/// A guest's look and feel.
public enum SimulatorLookAndFeel: String, CaseIterable, Sendable {
    /// The clear look and feel.
    case clear
    /// The tinted look and feel.
    case tinted
}

/// A guest's color filter.
public enum SimulatorColorFilter: String, CaseIterable, Sendable {
    /// No color filter.
    case none
    /// Grayscale.
    case grayscale
    /// The red and green filter for protanopia.
    case protanopia
    /// The green and red filter for deuteranopia.
    case deuteranopia
    /// The blue and yellow filter for tritanopia.
    case tritanopia
}

/// An audio route that a device can select.
public struct SimulatorAudioDevice: Sendable, Equatable {
    /// `systemDefault`, or a CoreAudio device UID. Pass this to ``DeviceSettingChange/audioInputDevice(_:)`` or
    /// ``DeviceSettingChange/audioOutputDevice(_:)``.
    public let identifier: String
    /// The route's display name.
    public var name: String

    /// Creates an audio-device description.
    /// - Parameters:
    ///   - identifier: The audio-device identifier used to select the route.
    ///   - name: The name to display for the route.
    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

/// A recorded route that a device can simulate.
public struct SimulatorLocationScenario: Sendable, Equatable {
    /// The name to pass to ``DeviceSettingChange/locationScenario(_:)``.
    public var name: String
    /// The route's display name.
    public var displayName: String

    /// Creates a recorded location-scenario description.
    /// - Parameters:
    ///   - name: The scenario identifier used to select the route.
    ///   - displayName: The name to display for the route.
    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

/// A Display Zoom mode that an iPhone or iPad simulator offers.
public struct SimulatorDisplayZoomMode: Sendable, Equatable, Codable {
    /// The value to pass to ``DeviceSettingChange/displayZoom(_:)``.
    public let rawMode: UInt64
    /// The guest's localized name for this mode.
    public var nativeName: String
    /// The width that the guest reports for this mode.
    public var width: Double
    /// The height that the guest reports for this mode.
    public var height: Double
}

/// The device's saved desired location. External live changes may differ.
public enum DeviceLocationMode: String, Sendable {
    /// No simulated location.
    case none
    /// A location set by coordinates.
    case custom
    /// A recorded route, named by ``DeviceSettingsState/locationScenario``.
    case scenario
}

/// Settings read as a group, sharing completion and failure status.
public enum DeviceSettingsGroup: String, CaseIterable, Sendable {
    /// ``DeviceSettingsState/appearance``.
    case appearance
    /// ``DeviceSettingsState/contentSize``.
    case textSize
    /// ``DeviceSettingsState/increaseContrast``.
    case contrast
    /// ``DeviceSettingsState/displayZoom`` and ``DeviceSettingsState/supportedDisplayZoomModes``.
    case displayZoom
    /// ``DeviceSettingsState/boldText``.
    case boldText
    /// Look and feel, Liquid Glass opacity, color filter, Reduce Motion, Show Borders, and Reduce Transparency.
    case accessibility
    /// ``DeviceSettingsState/voiceOver``.
    case voiceOver
    /// Volume and audio routes.
    case audio
    /// Simulated location and recorded routes.
    case location
}

/// A state group's last read result.
public enum DeviceReadStatus: Equatable, Sendable {
    /// Nothing has answered yet.
    case unread
    /// The last read answered in full.
    case current
    /// The last read failed or answered only in part. Its reason applies to the values that remain.
    case stale(String)
    /// The device does not have this, so reading again would not change the answer.
    case unsupported
}

/// One change to one device's settings.
///
/// Kit passes numeric values to the device unchanged. NeoSimulator's own controls use 0 through 1 for Liquid Glass opacity,
/// 0.25 through 1 for color filter intensity, and 0 through 100 for volume.
public enum DeviceSettingChange: Equatable, Sendable {
    /// Sets the light or dark appearance.
    case appearance(DeviceAppearance)
    /// Sets the preferred text size.
    case contentSize(DeviceContentSize)
    /// Turns Bold Text on or off. Only iPhone and iPad simulators support this.
    case boldText(Bool)
    /// Selects a Display Zoom mode by its ``SimulatorDisplayZoomMode/rawMode``. Only iPhone and iPad simulators support this.
    case displayZoom(UInt64)
    /// Turns Increase Contrast on or off.
    case increaseContrast(Bool)
    /// Sets the look and feel.
    case lookAndFeel(SimulatorLookAndFeel)
    /// Sets the Liquid Glass opacity.
    case liquidGlassOpacity(Double)
    /// Sets the color filter. Pass an intensity only for a filter that takes one; ``SimulatorColorFilter/none`` and
    /// ``SimulatorColorFilter/grayscale`` do not.
    case colorFilter(SimulatorColorFilter, intensity: Double? = nil)
    /// Turns Reduce Motion on or off.
    case reduceMotion(Bool)
    /// Turns Show Borders on or off.
    case showBorders(Bool)
    /// Turns Reduce Transparency on or off.
    case reduceTransparency(Bool)
    /// Turns VoiceOver on or off.
    case voiceOver(Bool)
    /// Sets the output volume.
    case volume(Int)
    /// Selects an audio input by its ``SimulatorAudioDevice/identifier``.
    case audioInputDevice(String)
    /// Selects an audio output by its ``SimulatorAudioDevice/identifier``.
    case audioOutputDevice(String)
    /// Simulates a location at these coordinates.
    case location(latitude: Double, longitude: Double)
    /// Runs a recorded route by its ``SimulatorLocationScenario/name``.
    case locationScenario(String)
    /// Stops simulating a location.
    case clearLocation

    /// The group whose status and reads this change affects.
    public var group: DeviceSettingsGroup {
        switch self {
        case .appearance: .appearance
        case .contentSize: .textSize
        case .increaseContrast: .contrast
        case .boldText: .boldText
        case .displayZoom: .displayZoom
        case .lookAndFeel, .liquidGlassOpacity, .colorFilter, .reduceMotion, .showBorders, .reduceTransparency: .accessibility
        case .voiceOver: .voiceOver
        case .volume, .audioInputDevice, .audioOutputDevice: .audio
        case .location, .locationScenario, .clearLocation: .location
        }
    }
}

/// A snapshot of guest settings, which ``DeviceSettingsState`` merges reads and accepted changes into. Nil means a value
/// is unknown or absent.
package struct SimulatorDeviceSettings: Sendable, Equatable {
    package var appearance: DeviceAppearance?
    package var contentSize: DeviceContentSize?
    package var boldText: Bool?
    package var displayZoom: SimulatorDisplayZoomMode?
    package var supportedDisplayZoomModes: [SimulatorDisplayZoomMode] = []
    package var increaseContrast: Bool?
    package var lookAndFeel: String?
    package var supportedLooksAndFeels: [SimulatorLookAndFeel] = []
    package var liquidGlassOpacity: Double?
    package var colorFilter: SimulatorColorFilter?
    package var colorFilterIntensity: Double?
    package var colorFilterRequiredOSVersion: Int?
    package var reduceMotion: Bool?
    package var showBorders: Bool?
    package var reduceTransparency: Bool?
    package var voiceOver: Bool?
    package var volume: Int?
    /// `systemDefault`, or a CoreAudio device UID.
    package var audioInputDevice: String?
    package var audioOutputDevice: String?
    package var audioInputDevices: [SimulatorAudioDevice] = []
    package var audioOutputDevices: [SimulatorAudioDevice] = []
    package var locationAvailable = false
    package var locationScenarios: [SimulatorLocationScenario] = []
    package var locationMode: DeviceLocationMode?
    package var locationScenario: String?

    package init(appearance: DeviceAppearance? = nil, contentSize: DeviceContentSize? = nil, boldText: Bool? = nil,
                 increaseContrast: Bool? = nil, liquidGlassOpacity: Double? = nil, colorFilter: SimulatorColorFilter? = nil,
                 reduceMotion: Bool? = nil, showBorders: Bool? = nil, reduceTransparency: Bool? = nil,
                 voiceOver: Bool? = nil, volume: Int? = nil) {
        self.appearance = appearance
        self.contentSize = contentSize
        self.boldText = boldText
        self.increaseContrast = increaseContrast
        self.liquidGlassOpacity = liquidGlassOpacity
        self.colorFilter = colorFilter
        self.reduceMotion = reduceMotion
        self.showBorders = showBorders
        self.reduceTransparency = reduceTransparency
        self.voiceOver = voiceOver
        self.volume = volume
    }

    /// Replaces what `group` holds with what `values` holds of it.
    package mutating func replace(_ group: DeviceSettingsGroup, with values: Self) {
        switch group {
        case .appearance: appearance = values.appearance
        case .textSize: contentSize = values.contentSize
        case .contrast: increaseContrast = values.increaseContrast
        case .boldText: boldText = values.boldText
        case .displayZoom:
            displayZoom = values.displayZoom
            supportedDisplayZoomModes = values.supportedDisplayZoomModes
        case .accessibility:
            lookAndFeel = values.lookAndFeel
            supportedLooksAndFeels = values.supportedLooksAndFeels
            liquidGlassOpacity = values.liquidGlassOpacity
            colorFilter = values.colorFilter
            colorFilterIntensity = values.colorFilterIntensity
            colorFilterRequiredOSVersion = values.colorFilterRequiredOSVersion
            reduceMotion = values.reduceMotion
            showBorders = values.showBorders
            reduceTransparency = values.reduceTransparency
        case .voiceOver: voiceOver = values.voiceOver
        case .audio:
            volume = values.volume
            audioInputDevice = values.audioInputDevice
            audioOutputDevice = values.audioOutputDevice
            audioInputDevices = values.audioInputDevices
            audioOutputDevices = values.audioOutputDevices
        case .location:
            locationAvailable = values.locationAvailable
            locationScenarios = values.locationScenarios
            locationMode = values.locationMode
            locationScenario = values.locationScenario
        }
    }

    /// Projects an accepted change until the device confirms its values.
    package func applying(_ change: DeviceSettingChange) -> Self {
        var result = self
        switch change {
        case .appearance(let value): result.appearance = value
        case .contentSize(let value): result.contentSize = value
        case .boldText(let value): result.boldText = value
        case .displayZoom(let value): result.displayZoom = result.supportedDisplayZoomModes.first { $0.rawMode == value }
        case .increaseContrast(let value): result.increaseContrast = value
        case .lookAndFeel(let value): result.lookAndFeel = value.rawValue
        case .liquidGlassOpacity(let value): result.liquidGlassOpacity = value
        case .colorFilter(let value, let intensity):
            result.colorFilter = value
            if let intensity { result.colorFilterIntensity = intensity }
        case .reduceMotion(let value): result.reduceMotion = value
        case .showBorders(let value): result.showBorders = value
        case .reduceTransparency(let value): result.reduceTransparency = value
        case .voiceOver(let value): result.voiceOver = value
        case .volume(let value): result.volume = value
        case .audioInputDevice(let value): result.audioInputDevice = value
        case .audioOutputDevice(let value): result.audioOutputDevice = value
        case .location:
            result.locationMode = .custom
            result.locationScenario = nil
        case .locationScenario(let value):
            result.locationMode = .scenario
            result.locationScenario = value
        case .clearLocation:
            result.locationMode = DeviceLocationMode.none
            result.locationScenario = nil
        }
        return result
    }

    package mutating func updateAudioRoutes(_ state: AudioRouteState) {
        func selection(_ value: String?) -> String? { value == AudioRouting.systemDefault ? "systemDefault" : value }
        let systemDefault = SimulatorAudioDevice(identifier: "systemDefault", name: "System Default")
        audioInputDevice = selection(state.inputRoute)
        audioOutputDevice = selection(state.outputRoute)
        audioInputDevices = [systemDefault] + state.devices(in: .input).map { SimulatorAudioDevice(identifier: $0.uid, name: $0.name) }
        audioOutputDevices = [systemDefault] + state.devices(in: .output).map { SimulatorAudioDevice(identifier: $0.uid, name: $0.name) }
    }
}

/// What one group's read answered. `apply` sets only the values that were read, so that a failure keeps the rest.
package struct DeviceSettingsGroupRead: Sendable {
    package enum Outcome: Sendable {
        /// `failures` names any values within the group that could not be read.
        case values
        case failed(String)
        case unsupported
    }

    package let group: DeviceSettingsGroup
    package let outcome: Outcome
    package var failures: [String] = []
    package var apply: @Sendable (inout SimulatorDeviceSettings) -> Void = { _ in }

    package static func values(_ group: DeviceSettingsGroup, failures: [String] = [],
                               apply: @escaping @Sendable (inout SimulatorDeviceSettings) -> Void) -> Self {
        Self(group: group, outcome: .values, failures: failures, apply: apply)
    }

    package static func failed(_ group: DeviceSettingsGroup, _ reason: String) -> Self {
        Self(group: group, outcome: .failed(reason))
    }

    package static func unsupported(_ group: DeviceSettingsGroup) -> Self {
        Self(group: group, outcome: .unsupported)
    }
}

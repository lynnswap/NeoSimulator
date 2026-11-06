import Foundation

public enum DeviceAppearance: String, CaseIterable, Sendable {
    case light, dark
}

/// The guest's preferred text size, smallest first. Raw values are `devicectl`'s.
public enum DeviceContentSize: String, CaseIterable, Sendable {
    case extraSmall = "extra-small", small, medium, large, extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large", extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium", accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"
}

public enum SimulatorLookAndFeel: String, CaseIterable, Sendable {
    case clear, tinted
}

public enum SimulatorColorFilter: String, CaseIterable, Sendable {
    case none, grayscale, protanopia, deuteranopia, tritanopia
}

public struct SimulatorAudioDevice: Sendable, Equatable {
    public let identifier: String
    public let name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

public struct SimulatorLocationScenario: Sendable, Equatable {
    public let name: String
    public let displayName: String

    public init(name: String, displayName: String) {
        self.name = name
        self.displayName = displayName
    }
}

public struct SimulatorDisplayZoomMode: Sendable, Equatable, Codable {
    public let rawMode: UInt64
    public let nativeName: String
    public let width: Double
    public let height: Double
}

/// The device's saved desired location. External live changes may differ.
public enum DeviceLocationMode: String, Sendable {
    case none, custom, scenario
}

/// Settings that one read of the device answers together, and that change and fail together.
public enum DeviceSettingsGroup: String, CaseIterable, Sendable {
    case appearance, textSize, contrast, displayZoom, boldText, accessibility, voiceOver, audio, location
}

/// What is known of a group: what the last read answered.
public enum DeviceReadStatus: Equatable, Sendable {
    /// Nothing has answered yet.
    case unread
    case current
    /// The last read failed. Its reason applies to the values that remain from the read before.
    case stale(String)
    /// The device does not have these settings.
    case unsupported
}

/// One change to one device's settings.
public enum DeviceSettingChange: Equatable, Sendable {
    case appearance(DeviceAppearance)
    case contentSize(DeviceContentSize)
    case boldText(Bool)
    case displayZoom(UInt64)
    case increaseContrast(Bool)
    case lookAndFeel(SimulatorLookAndFeel)
    case liquidGlassOpacity(Double)
    case colorFilter(SimulatorColorFilter, intensity: Double? = nil)
    case reduceMotion(Bool)
    case showBorders(Bool)
    case reduceTransparency(Bool)
    case voiceOver(Bool)
    case volume(Int)
    case audioInputDevice(String)
    case audioOutputDevice(String)
    case location(latitude: Double, longitude: Double)
    case locationScenario(String)
    case clearLocation

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

import Foundation

enum ReceiptStatus: Equatable {
    case unmanaged
    case managed(original: ManagedPreferenceState)
    case pendingBefore
    case pendingTarget
    case ambiguousIntermediate
    case conflict(expected: ManagedPreferenceState, observed: ManagedPreferenceState)

    var hasConflict: Bool {
        if case .conflict = self {
            return true
        }
        return self == .ambiguousIntermediate
    }
}

struct SimulatorRouteStatus: Equatable {
    let preferences: ManagedPreferenceState
    let receiptStatus: ReceiptStatus

}

struct ModeChangeReport: Equatable {
    let host: ResolvedHost
    let didChangePreferences: Bool
    let xcode: XcodeInstallation
    let receiptURL: URL?
    let terminatedDeviceHubCount: Int
    let terminatedNeoHostCount: Int
}

struct RestoreReport: Equatable {
    let didRestore: Bool
    let restoredState: ManagedPreferenceState?
    let receiptURL: URL
    let terminatedNeoHostCount: Int
}

public struct SimulatorDeviceSettings: Sendable {
    public static let contentSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]
    public let appearance: String?
    public let contentSize: String?
    public let increaseContrast: Bool?
    public let locationAvailable: Bool
    public let issues: [String]
}

public enum SimulatorDeviceSetting: Sendable {
    case appearance(String)
    case contentSize(String)
    case increaseContrast(Bool)
    case location(latitude: Double, longitude: Double)
    case clearLocation
}

extension SimulatorHostController {
    public func deviceSettings(identifier: String) async throws -> SimulatorDeviceSettings {
        do {
            let (device, xcodeURL) = try await settingsDevice(identifier)
            guard device.state == "Booted" else {
                return SimulatorDeviceSettings(appearance: nil, contentSize: nil, increaseContrast: nil, locationAvailable: false, issues: [])
            }
            var issues: [String] = []
            func read(_ setting: String) -> String? {
                do { return try runSettingsCommand(xcodeURL: xcodeURL, arguments: ["ui", identifier, setting]) }
                catch {
                    issues.append("\(setting): \(error.localizedDescription)")
                    return nil
                }
            }
            let appearance = read("appearance")
            let size = read("content_size")
            let contrast = read("increase_contrast")
            let locationAvailable: Bool
            do {
                _ = try runSettingsCommand(xcodeURL: xcodeURL, arguments: ["location", identifier, "list"])
                locationAvailable = true
            } catch {
                issues.append("location: \(error.localizedDescription)")
                locationAvailable = false
            }
            return SimulatorDeviceSettings(
                appearance: appearance.flatMap { ["light", "dark"].contains($0) ? $0 : nil },
                contentSize: size.flatMap { SimulatorDeviceSettings.contentSizes.contains($0) ? $0 : nil },
                increaseContrast: contrast == "enabled" ? true : contrast == "disabled" ? false : nil,
                locationAvailable: locationAvailable,
                issues: issues
            )
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    public func setDeviceSetting(_ setting: SimulatorDeviceSetting, identifier: String) async throws {
        do {
            let (_, xcodeURL) = try await settingsDevice(identifier)
            let arguments: [String] = switch setting {
            case .appearance(let value): ["ui", identifier, "appearance", value]
            case .contentSize(let value): ["ui", identifier, "content_size", value]
            case .increaseContrast(let enabled): ["ui", identifier, "increase_contrast", enabled ? "enabled" : "disabled"]
            case .location(let latitude, let longitude):
                ["location", identifier, "set", "\(latitude),\(longitude)"]
            case .clearLocation: ["location", identifier, "clear"]
            }
            _ = try runSettingsCommand(xcodeURL: xcodeURL, arguments: arguments)
            let preset: [String: Any]?
            switch setting {
            case .location(let latitude, let longitude): preset = ["mode": "custom", "latitude": latitude, "longitude": longitude]
            case .clearLocation: preset = ["mode": "none"]
            default: preset = nil
            }
            if let preset {
                guard let defaults = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator") else {
                    throw CLIError.io("device-location-save", "The location was applied, but could not be saved for the next connection.")
                }
                defaults.set(preset, forKey: "DeviceLocationPreset.\(identifier)")
                guard defaults.synchronize() else {
                    throw CLIError.io("device-location-save", "The location was applied, but could not be saved for the next connection.")
                }
            }
        } catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    private func settingsDevice(_ identifier: String) async throws -> (SimulatorHostDevice, URL) {
        let xcodeURL = try await self.xcodeURL(forDevice: identifier)
        guard let device = try await devices(xcodeURL: xcodeURL).first(where: { $0.identifier == identifier }) else {
            throw CLIError.unavailable("simulator-device", "The selected simulator is no longer available.")
        }
        return (device, xcodeURL)
    }

    private func runSettingsCommand(xcodeURL: URL, arguments: [String]) throws -> String {
        let result = try SystemCommandRunner().run(
            executable: xcodeURL.appendingPathComponent(ToolConstants.simctlWrapperPath), arguments: arguments)
        guard result.terminationStatus == 0 else { throw CLIError.io("device-setting", result.stderrText) }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

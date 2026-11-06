import Foundation
import NeoSimulatorDeviceIO

package struct XcodeInstallationInspector {
    private static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
    private let runner: any CommandRunning
    private let environment: [String: String]

    package init(runner: any CommandRunning = SystemCommandRunner(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.environment = environment
    }

    package nonisolated(nonsending) func selectedXcode() async throws -> XcodeInstallation {
        let developerDirectory = try await selectedDeveloperDirectory()
        let xcodeURL = try xcodeApplicationURL(forDeveloperDirectory: developerDirectory)
        return try xcode(at: xcodeURL)
    }

    /// Nil when no usable Xcode is selected. Cancellation still throws, because it says nothing about the selection.
    package nonisolated(nonsending) func selectedXcodeIfUsable() async throws -> XcodeInstallation? {
        do { return try await selectedXcode() }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    package nonisolated(nonsending) func xcodeForUIFrameworks(override: URL?) async throws -> XcodeInstallation {
        if let override { return try xcode(at: override) }
        return try await selectedXcode()
    }

    package func xcode(at url: URL) throws -> XcodeInstallation {
        let xcode = try inspectXcode(at: url.resolvingSymlinksInPath().standardizedFileURL)

        guard xcode.version.major >= ToolConstants.minimumSupportedXcodeMajorVersion else {
            throw CLIError.unavailable(
                "unsupported-xcode",
                "Xcode \(xcode.version) is selected; Xcode 27 or later is required"
            )
        }
        return xcode
    }

    private nonisolated(nonsending) func selectedDeveloperDirectory() async throws -> URL {
        if let path = environment["DEVELOPER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        let output = try await runner.runCancellable(SystemCommand(executable: Self.xcodeSelect, arguments: ["-p"], policy: .cancellable))
        guard output.terminationStatus == 0, !output.stdoutText.isEmpty else {
            let detail = output.stderrText.isEmpty
                ? "exit status \(output.terminationStatus)"
                : output.stderrText
            throw CLIError.unavailable(
                "selected-xcode",
                "xcode-select could not resolve an Xcode: \(detail)"
            )
        }
        return URL(fileURLWithPath: output.stdoutText, isDirectory: true).standardizedFileURL
    }

    private func xcodeApplicationURL(forDeveloperDirectory url: URL) throws -> URL {
        guard url.lastPathComponent == "Developer" else {
            throw CLIError.unavailable(
                "developer-directory",
                "DEVELOPER_DIR must end in Contents/Developer: \(url.path)"
            )
        }
        let contentsURL = url.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else {
            throw CLIError.unavailable(
                "developer-directory",
                "DEVELOPER_DIR must end in Contents/Developer: \(url.path)"
            )
        }
        return contentsURL.deletingLastPathComponent().standardizedFileURL
    }

    private func inspectXcode(at applicationURL: URL) throws -> XcodeInstallation {
        let info = try propertyList(
            at: applicationURL.appendingPathComponent("Contents/Info.plist")
        )
        guard info["CFBundleIdentifier"] as? String == ToolConstants.xcodeBundleIdentifier,
              let versionString = info["CFBundleShortVersionString"] as? String
        else {
            throw CLIError.unavailable(
                "xcode-bundle",
                "\(applicationURL.path) is not a valid Xcode application"
            )
        }
        let version = try ToolVersion(versionString)

        let versionInfo = try propertyList(
            at: applicationURL.appendingPathComponent("Contents/version.plist")
        )
        guard let buildVersion = versionInfo["ProductBuildVersion"] as? String else {
            throw CLIError.unavailable(
                "xcode-build-version",
                "\(applicationURL.path) has no ProductBuildVersion"
            )
        }
        return XcodeInstallation(
            applicationURL: applicationURL,
            version: version,
            buildVersion: buildVersion
        )
    }

    package func propertyList(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError.unavailable(
                "bundle-property-list",
                "could not read \(url.path): \(error.localizedDescription)"
            )
        }

        do {
            let object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let dictionary = object as? [String: Any] else {
                throw CLIError.configuration(
                    "bundle-property-list",
                    "\(url.path) is not a dictionary"
                )
            }
            return dictionary
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.configuration(
                "bundle-property-list",
                "could not decode \(url.path): \(error.localizedDescription)"
            )
        }
    }
}

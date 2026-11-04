import NeoSimulatorKit
import Darwin
import Foundation

package struct InstallationInspector {
    private static let forbiddenCoreDeviceLoadPathFragments = [
        "/DeviceKit.framework/",
        "/DeviceHub.app/",
    ]

    private let runner: any CommandRunning
    private let fileManager: FileManager
    package let xcodes: XcodeInstallationInspector
    private let rendererApplicationURL: URL
    private let coreSimulatorFrameworkURL: URL
    private let coreDeviceFrameworkURL: URL
    private let signatureValidator: CodeSignatureValidator

    package init(
        runner: any CommandRunning,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rendererApplicationURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/NeoSimulatorRenderer.app", isDirectory: true),
        coreSimulatorFrameworkURL: URL = URL(
            fileURLWithPath: ToolConstants.coreSimulatorFrameworkPath,
            isDirectory: true
        ),
        coreDeviceFrameworkURL: URL = URL(
            fileURLWithPath: ToolConstants.coreDeviceFrameworkPath,
            isDirectory: true
        ),
        signatureValidator: CodeSignatureValidator = .live
    ) {
        self.runner = runner
        self.fileManager = fileManager
        xcodes = XcodeInstallationInspector(runner: runner, environment: environment)
        self.rendererApplicationURL = rendererApplicationURL
        self.coreSimulatorFrameworkURL = coreSimulatorFrameworkURL.standardizedFileURL
        self.coreDeviceFrameworkURL = coreDeviceFrameworkURL.standardizedFileURL
        self.signatureValidator = signatureValidator
    }

    package func validatedTargetXcode(at explicitURL: URL? = nil) throws -> XcodeInstallation {
        let xcode = try xcodes.xcodeForUIFrameworks(override: explicitURL)
        try signatureValidator.validateAppleApplication(
            xcode.applicationURL,
            ToolConstants.xcodeBundleIdentifier
        )

        let deviceHubURL = xcode.deviceHubApplicationURL
        let deviceHubInfo = try xcodes.propertyList(
            at: deviceHubURL.appendingPathComponent("Contents/Info.plist")
        )
        guard deviceHubInfo["CFBundleIdentifier"] as? String
                == ToolConstants.deviceHubBundleIdentifier,
              let deviceHubExecutable = deviceHubInfo["CFBundleExecutable"] as? String
        else {
            throw CLIError.unavailable(
                "device-hub-bundle",
                "the selected Xcode does not contain the expected Device Hub"
            )
        }
        try signatureValidator.validateAppleApplication(
            deviceHubURL,
            ToolConstants.deviceHubBundleIdentifier
        )
        let deviceHubExecutableURL = deviceHubURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(deviceHubExecutable)
        try requireExecutable(
            at: deviceHubExecutableURL,
            identifier: "device-hub-executable"
        )

        let deviceHubImplementationURL = deviceHubURL
            .appendingPathComponent(ToolConstants.deviceHubImplementationPath)
        try requireExecutable(
            at: deviceHubImplementationURL,
            identifier: "device-hub-implementation"
        )
        let deviceKitBinaryURL = try validatedFrameworkBinary(
            at: xcode.applicationURL.appendingPathComponent(
                ToolConstants.deviceKitPath,
                isDirectory: true
            ),
            expectedBundleIdentifier: ToolConstants.deviceKitBundleIdentifier,
            identifier: "device-kit"
        )
        try validateSurface(
            of: deviceKitBinaryURL,
            requiredStrings: [ToolConstants.deviceHubPreference.key],
            identifier: "device-hub-preference-key",
            description: "Device Hub in Xcode \(xcode.version) build \(xcode.buildVersion)"
        )

        let xcodeProbeURL = xcode.applicationURL
            .appendingPathComponent(ToolConstants.ideIOSSupportCorePath)
        try validateSurface(
            of: xcodeProbeURL,
            requiredStrings: [ToolConstants.xcodePreference.key],
            identifier: "xcode-preference-key",
            description: "Xcode \(xcode.version) build \(xcode.buildVersion)"
        )
        return xcode
    }

    package func validatedNeoHost(
        for xcode: XcodeInstallation
    ) throws -> NeoHostInstallation {
        let simctlWrapperURL = xcode.applicationURL.appendingPathComponent(
            ToolConstants.simctlWrapperPath
        )
        let coreSimulatorVersion = try expectedVersion(
            inWrapperAt: simctlWrapperURL,
            identifier: "simctl-wrapper"
        )
        let devicectlWrapperURL = xcode.applicationURL.appendingPathComponent(
            ToolConstants.devicectlWrapperPath
        )
        let coreDeviceVersion = try expectedVersion(
            inWrapperAt: devicectlWrapperURL,
            identifier: "devicectl-wrapper"
        )

        let simulatorKitBinaryURL = try validatedFrameworkBinary(
            at: xcode.applicationURL.appendingPathComponent(
                ToolConstants.simulatorKitPath,
                isDirectory: true
            ),
            expectedBundleIdentifier: ToolConstants.simulatorKitBundleIdentifier,
            identifier: "simulator-kit"
        )
        let idePlaygroundSimulatorBinaryURL = try validatedFrameworkBinary(
            at: xcode.applicationURL.appendingPathComponent(
                ToolConstants.idePlaygroundSimulatorPath,
                isDirectory: true
            ),
            expectedBundleIdentifier: ToolConstants.idePlaygroundSimulatorBundleIdentifier,
            identifier: "ide-playground-simulator"
        )
        let coreSimulatorBinaryURL = try validatedFrameworkBinary(
            at: coreSimulatorFrameworkURL,
            expectedBundleIdentifier: ToolConstants.coreSimulatorBundleIdentifier,
            identifier: "core-simulator"
        )
        let simctlBinaryURL = coreSimulatorFrameworkURL.appendingPathComponent(
            ToolConstants.simctlBinaryPath
        )
        try validateAppleExecutable(
            at: simctlBinaryURL,
            expectedIdentifier: ToolConstants.simctlBundleIdentifier,
            identifier: "simctl"
        )

        let coreDeviceBinaryURL = try validatedFrameworkBinary(
            at: coreDeviceFrameworkURL,
            expectedBundleIdentifier: ToolConstants.coreDeviceBundleIdentifier,
            identifier: "core-device"
        )
        let devicectlBinaryURL = coreDeviceFrameworkURL.appendingPathComponent(
            ToolConstants.devicectlBinaryPath
        )
        try validateAppleExecutable(
            at: devicectlBinaryURL,
            expectedIdentifier: ToolConstants.devicectlBundleIdentifier,
            identifier: "devicectl"
        )
        try rejectForbiddenLoadPaths(
            in: devicectlBinaryURL,
            identifier: "devicectl-linkage"
        )

        let simulatorCoreDevicePluginURL = coreDeviceFrameworkURL
            .appendingPathComponent(
                ToolConstants.simulatorCoreDevicePluginPath,
                isDirectory: true
            )
        let simulatorCoreDevicePluginBinaryURL =
            try validatedSimulatorCoreDevicePlugin(
                at: simulatorCoreDevicePluginURL
            )
        try rejectForbiddenLoadPaths(
            in: simulatorCoreDevicePluginBinaryURL,
            identifier: "simulator-core-device-plugin-linkage"
        )

        let applicationURL = neoHostApplicationURL()
        let applicationExecutableURL = try validatedApplicationExecutable(
            at: applicationURL,
            expectedBundleIdentifier: ToolConstants.neoHostBundleIdentifier,
            identifier: "neo-host"
        )
        try validateNeoHostRuntime(
            executableURL: applicationExecutableURL,
            xcode: xcode
        )

        return NeoHostInstallation(
            applicationURL: applicationURL,
            xcode: xcode,
            simulatorKitBinaryURL: simulatorKitBinaryURL,
            idePlaygroundSimulatorBinaryURL: idePlaygroundSimulatorBinaryURL,
            coreSimulatorBinaryURL: coreSimulatorBinaryURL,
            coreSimulatorVersion: coreSimulatorVersion,
            simctlWrapperURL: simctlWrapperURL,
            simctlBinaryURL: simctlBinaryURL,
            coreDeviceBinaryURL: coreDeviceBinaryURL,
            coreDeviceVersion: coreDeviceVersion,
            devicectlWrapperURL: devicectlWrapperURL,
            devicectlBinaryURL: devicectlBinaryURL,
            simulatorCoreDevicePluginBinaryURL: simulatorCoreDevicePluginBinaryURL
        )
    }

    package func neoHostApplicationURL() -> URL {
        URL(fileURLWithPath: rendererApplicationURL.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }

    private func validatedApplicationExecutable(
        at applicationURL: URL,
        expectedBundleIdentifier: String,
        identifier: String
    ) throws -> URL {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.isReadableFile(atPath: infoURL.path) else {
            throw CLIError.unavailable(
                "\(identifier)-bundle",
                "missing application bundle at \(applicationURL.path)"
            )
        }
        let info = try xcodes.propertyList(at: infoURL)
        guard info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty
        else {
            throw CLIError.unavailable(
                "\(identifier)-bundle",
                "\(applicationURL.path) is not the expected \(expectedBundleIdentifier) application"
            )
        }
        let executableURL = applicationURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executable)
        try requireExecutable(
            at: executableURL,
            identifier: "\(identifier)-executable"
        )
        return executableURL
    }

    private func expectedVersion(
        inWrapperAt wrapperURL: URL,
        identifier: String
    ) throws -> String {
        try requireExecutable(at: wrapperURL, identifier: identifier)
        let data = try binaryData(
            at: wrapperURL,
            identifier: "\(identifier)-version"
        )
        guard let source = String(data: data, encoding: .utf8) else {
            throw CLIError.unavailable(
                "\(identifier)-version",
                "\(wrapperURL.path) is not a UTF-8 wrapper script"
            )
        }

        let assignmentLines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).filter(isExpectedVersionAssignment)
        let prefix = "EXPECTED_VERSION=\""
        guard assignmentLines.count == 1,
              let assignment = assignmentLines.first,
              assignment.hasPrefix(prefix),
              assignment.hasSuffix("\"")
        else {
            throw CLIError.unavailable(
                "\(identifier)-version",
                "\(wrapperURL.path) must contain exactly one EXPECTED_VERSION=\"<numeric version>\" literal"
            )
        }

        let valueStart = assignment.index(
            assignment.startIndex,
            offsetBy: prefix.count
        )
        let valueEnd = assignment.index(before: assignment.endIndex)
        let version = String(assignment[valueStart..<valueEnd])
        let components = version.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component.utf8.allSatisfy { byte in
                          byte >= 48 && byte <= 57
                      }
              })
        else {
            throw CLIError.unavailable(
                "\(identifier)-version",
                "\(wrapperURL.path) has an invalid EXPECTED_VERSION literal"
            )
        }
        return version
    }

    private func isExpectedVersionAssignment(_ line: Substring) -> Bool {
        let trimmed = line.drop { character in
            character == " " || character == "\t"
        }
        guard !trimmed.hasPrefix("#"),
              let nameRange = trimmed.range(of: "EXPECTED_VERSION")
        else {
            return false
        }
        let suffix = trimmed[nameRange.upperBound...].drop { character in
            character == " " || character == "\t"
        }
        return suffix.hasPrefix("=")
    }

    private func validatedFrameworkBinary(
        at frameworkURL: URL,
        expectedBundleIdentifier: String,
        identifier: String
    ) throws -> URL {
        let infoURL = frameworkURL.appendingPathComponent(
            "Versions/A/Resources/Info.plist"
        )
        guard fileManager.isReadableFile(atPath: infoURL.path) else {
            throw CLIError.unavailable(
                "\(identifier)-bundle",
                "missing framework bundle at \(frameworkURL.path)"
            )
        }
        let info = try xcodes.propertyList(at: infoURL)
        guard info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty
        else {
            throw CLIError.unavailable(
                "\(identifier)-bundle",
                "\(frameworkURL.path) is not the expected \(expectedBundleIdentifier) framework"
            )
        }
        try signatureValidator.validateAppleCode(
            frameworkURL,
            expectedBundleIdentifier
        )

        let executableURL = frameworkURL
            .appendingPathComponent("Versions/A", isDirectory: true)
            .appendingPathComponent(executable)
        try requireExecutable(
            at: executableURL,
            identifier: "\(identifier)-executable"
        )
        return executableURL
    }

    private func validatedSimulatorCoreDevicePlugin(
        at pluginURL: URL
    ) throws -> URL {
        let infoURL = pluginURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.isReadableFile(atPath: infoURL.path) else {
            throw CLIError.unavailable(
                "simulator-core-device-plugin-bundle",
                "missing plugin bundle at \(pluginURL.path)"
            )
        }
        let info = try xcodes.propertyList(at: infoURL)
        guard info["CFBundleIdentifier"] as? String
                == ToolConstants.simulatorCoreDevicePluginBundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty
        else {
            throw CLIError.unavailable(
                "simulator-core-device-plugin-bundle",
                "\(pluginURL.path) is not the expected \(ToolConstants.simulatorCoreDevicePluginBundleIdentifier) plugin"
            )
        }
        try signatureValidator.validateAppleCode(
            pluginURL,
            ToolConstants.simulatorCoreDevicePluginBundleIdentifier
        )

        let executableURL = pluginURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executable)
        try requireExecutable(
            at: executableURL,
            identifier: "simulator-core-device-plugin-executable"
        )
        return executableURL
    }

    private func validateAppleExecutable(
        at executableURL: URL,
        expectedIdentifier: String,
        identifier: String
    ) throws {
        try requireExecutable(at: executableURL, identifier: identifier)
        try signatureValidator.validateAppleCode(
            executableURL,
            expectedIdentifier
        )
    }

    private func rejectForbiddenLoadPaths(
        in binaryURL: URL,
        identifier: String
    ) throws {
        let binary = try binaryData(at: binaryURL, identifier: identifier)
        for fragment in Self.forbiddenCoreDeviceLoadPathFragments {
            guard binary.range(of: Data(fragment.utf8)) == nil else {
                throw CLIError.unavailable(
                    identifier,
                    "\(binaryURL.path) requires forbidden DeviceKit/Device Hub component \(fragment)"
                )
            }
        }
    }

    private func validateSurface(
        of binaryURL: URL,
        requiredStrings: [String],
        identifier: String,
        description: String
    ) throws {
        let binary = try binaryData(at: binaryURL, identifier: identifier)
        for requiredString in requiredStrings {
            guard binary.range(of: Data(requiredString.utf8)) != nil else {
                throw CLIError.unavailable(
                    identifier,
                    "\(description) no longer contains the required private surface \(requiredString)"
                )
            }
        }
    }

    private func validateNeoHostRuntime(
        executableURL: URL,
        xcode: XcodeInstallation
    ) throws {
        let output = try runner.run(
            executable: executableURL,
            arguments: [
                "--validate-runtime",
                "--xcode",
                xcode.applicationURL.path,
            ]
        )
        guard output.terminationStatus == 0 else {
            let detail = if !output.stderrText.isEmpty {
                output.stderrText
            } else if !output.stdoutText.isEmpty {
                output.stdoutText
            } else {
                "exit status \(output.terminationStatus)"
            }
            throw CLIError.unavailable(
                "neo-host-runtime",
                "NeoSimulator rejected Xcode \(xcode.version) build \(xcode.buildVersion): \(detail)"
            )
        }
    }

    private func requireExecutable(at url: URL, identifier: String) throws {
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw CLIError.unavailable(
                identifier,
                "missing executable at \(url.path)"
            )
        }
    }

    private func binaryData(at url: URL, identifier: String) throws -> Data {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw CLIError.unavailable(
                identifier,
                "missing readable binary at \(url.path)"
            )
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CLIError.io(
                identifier,
                "could not read \(url.path): \(error.localizedDescription)"
            )
        }
    }

}

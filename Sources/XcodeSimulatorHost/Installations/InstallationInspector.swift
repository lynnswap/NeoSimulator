import Darwin
import Foundation

struct InstallationInspector {
    private static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")

    private static let simulatorKitRequiredSurface = [
        "_TtC12SimulatorKit14SimDisplayView",
        "_TtC12SimulatorKit15SimDeviceScreen",
        "_TtC12SimulatorKit24SimDeviceLegacyHIDClient",
        "isDefault",
        "IndigoHIDMessageForButton",
    ]

    private static let idePlaygroundSimulatorRequiredSurface = [
        "_TtC22IDEPlaygroundSimulator27IDESimulatorPlaygroundUntil",
        "createSimDisplayViewWithDevice:simScreenID:",
    ]

    private static let coreSimulatorRequiredSurface = [
        "SimServiceContext",
        "sharedServiceContextForDeveloperDir:error:",
        "defaultDeviceSetWithError:",
        "availableDevices",
        "registerNotificationHandlerOnQueue:handler:",
    ]

    private static let forbiddenCoreDeviceLoadPathFragments = [
        "/DeviceKit.framework/",
        "/DeviceHub.app/",
    ]

    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let environment: [String: String]
    private let commandExecutableURL: URL?
    private let coreSimulatorFrameworkURL: URL
    private let coreDeviceFrameworkURL: URL
    private let signatureValidator: CodeSignatureValidator

    init(
        runner: any CommandRunning,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandExecutableURL: URL? = nil,
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
        self.environment = environment
        self.commandExecutableURL = commandExecutableURL
        self.coreSimulatorFrameworkURL = coreSimulatorFrameworkURL.standardizedFileURL
        self.coreDeviceFrameworkURL = coreDeviceFrameworkURL.standardizedFileURL
        self.signatureValidator = signatureValidator
    }

    func validatedTargetXcode() throws -> XcodeInstallation {
        let developerDirectory = try selectedDeveloperDirectory()
        let xcodeURL = try xcodeApplicationURL(forDeveloperDirectory: developerDirectory)
        let xcode = try inspectXcode(at: xcodeURL)

        guard xcode.version.major >= ToolConstants.minimumSupportedXcodeMajorVersion else {
            throw CLIError.unavailable(
                "unsupported-xcode",
                "Xcode \(xcode.version) is selected; Xcode 27 or later is required"
            )
        }
        try signatureValidator.validateAppleCode(
            xcode.applicationURL,
            ToolConstants.xcodeBundleIdentifier
        )

        let deviceHubURL = xcode.deviceHubApplicationURL
        let deviceHubInfo = try propertyList(
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
        try signatureValidator.validateAppleCode(
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
        try validateSurface(
            of: deviceHubImplementationURL,
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

    func validatedLegacyHost(
        for xcode: XcodeInstallation
    ) throws -> LegacyHostInstallation {
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
            identifier: "simulator-kit",
            requiredXcodeMajorVersion: xcode.version.major,
            requiredSurface: Self.simulatorKitRequiredSurface
        )
        let idePlaygroundSimulatorBinaryURL = try validatedFrameworkBinary(
            at: xcode.applicationURL.appendingPathComponent(
                ToolConstants.idePlaygroundSimulatorPath,
                isDirectory: true
            ),
            expectedBundleIdentifier: ToolConstants.idePlaygroundSimulatorBundleIdentifier,
            identifier: "ide-playground-simulator",
            requiredXcodeMajorVersion: xcode.version.major,
            requiredSurface: Self.idePlaygroundSimulatorRequiredSurface
        )
        let coreSimulatorBinaryURL = try validatedFrameworkBinary(
            at: coreSimulatorFrameworkURL,
            expectedBundleIdentifier: ToolConstants.coreSimulatorBundleIdentifier,
            identifier: "core-simulator",
            requiredXcodeMajorVersion: xcode.version.major,
            requiredBundleVersion: coreSimulatorVersion,
            requiredSurface: Self.coreSimulatorRequiredSurface
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
            identifier: "core-device",
            requiredXcodeMajorVersion: xcode.version.major,
            requiredBundleVersion: coreDeviceVersion,
            requiredSurface: []
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
                at: simulatorCoreDevicePluginURL,
                requiredXcodeMajorVersion: xcode.version.major,
                requiredBundleVersion: coreSimulatorVersion
            )
        try rejectForbiddenLoadPaths(
            in: simulatorCoreDevicePluginBinaryURL,
            identifier: "simulator-core-device-plugin-linkage"
        )

        let applicationURL = try legacyHostApplicationURL()
        _ = try validatedApplicationExecutable(
            at: applicationURL,
            expectedBundleIdentifier: ToolConstants.legacyHostBundleIdentifier,
            identifier: "legacy-host"
        )

        return LegacyHostInstallation(
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

    func legacyHostApplicationURL() throws -> URL {
        let executableURL = try resolvedCommandExecutableURL()
        return executableURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ToolConstants.legacyHostRelativePath,
                isDirectory: true
            )
            .standardizedFileURL
    }

    private func resolvedCommandExecutableURL() throws -> URL {
        if let commandExecutableURL {
            return commandExecutableURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }

        var requiredSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &requiredSize)
        guard requiredSize > 0 else {
            throw CLIError.software(
                "command-executable",
                "could not determine the running command path"
            )
        }

        var buffer = [CChar](repeating: 0, count: Int(requiredSize))
        guard _NSGetExecutablePath(&buffer, &requiredSize) == 0 else {
            throw CLIError.software(
                "command-executable",
                "the running command path changed while it was being resolved"
            )
        }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .resolvingSymlinksInPath()
            .standardizedFileURL
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
        let info = try propertyList(at: infoURL)
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
        identifier: String,
        requiredXcodeMajorVersion: Int,
        requiredBundleVersion: String? = nil,
        requiredSurface: [String]
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
        let info = try propertyList(at: infoURL)
        guard info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              let dtXcodeString = info["DTXcode"] as? String,
              let dtXcode = Int(dtXcodeString),
              dtXcode / 100 == requiredXcodeMajorVersion,
              (requiredBundleVersion.map {
                  info["CFBundleVersion"] as? String == $0
              } ?? true)
        else {
            throw CLIError.unavailable(
                "\(identifier)-bundle",
                "\(frameworkURL.path) is not the expected Xcode \(requiredXcodeMajorVersion) \(expectedBundleIdentifier) framework"
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
        try validateSurface(
            of: executableURL,
            requiredStrings: requiredSurface,
            identifier: "\(identifier)-surface",
            description: expectedBundleIdentifier
        )
        return executableURL
    }

    private func validatedSimulatorCoreDevicePlugin(
        at pluginURL: URL,
        requiredXcodeMajorVersion: Int,
        requiredBundleVersion: String
    ) throws -> URL {
        let infoURL = pluginURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.isReadableFile(atPath: infoURL.path) else {
            throw CLIError.unavailable(
                "simulator-core-device-plugin-bundle",
                "missing plugin bundle at \(pluginURL.path)"
            )
        }
        let info = try propertyList(at: infoURL)
        guard info["CFBundleIdentifier"] as? String
                == ToolConstants.simulatorCoreDevicePluginBundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              info["CFBundleVersion"] as? String == requiredBundleVersion,
              let dtXcodeString = info["DTXcode"] as? String,
              let dtXcode = Int(dtXcodeString),
              dtXcode / 100 == requiredXcodeMajorVersion
        else {
            throw CLIError.unavailable(
                "simulator-core-device-plugin-bundle",
                "\(pluginURL.path) is not the expected Xcode \(requiredXcodeMajorVersion) \(ToolConstants.simulatorCoreDevicePluginBundleIdentifier) plugin at version \(requiredBundleVersion)"
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

    private func selectedDeveloperDirectory() throws -> URL {
        if let path = environment["DEVELOPER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        let output = try runner.run(executable: Self.xcodeSelect, arguments: ["-p"])
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

    private func propertyList(at url: URL) throws -> [String: Any] {
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

import Foundation

struct InstallationInspector {
    private static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")

    private let runner: any CommandRunning
    private let fileManager: FileManager
    private let environment: [String: String]
    private let legacySearchRoots: [URL]
    private let signatureValidator: CodeSignatureValidator

    init(
        runner: any CommandRunning,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacySearchRoots: [URL]? = nil,
        signatureValidator: CodeSignatureValidator = .live
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.environment = environment
        self.signatureValidator = signatureValidator
        self.legacySearchRoots = legacySearchRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    func validatedTargetXcode() throws -> XcodeInstallation {
        let developerDirectory = try selectedDeveloperDirectory()
        let xcodeURL = try xcodeApplicationURL(forDeveloperDirectory: developerDirectory)
        let xcode = try inspectXcode(at: xcodeURL)

        guard xcode.version.major == ToolConstants.supportedXcodeMajorVersion else {
            throw CLIError.unavailable(
                "unsupported-xcode",
                "Xcode \(xcode.version) is selected; only Xcode 27 is supported"
            )
        }

        let deviceHubURL = xcode.applicationURL
            .appendingPathComponent(ToolConstants.deviceHubPath, isDirectory: true)
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
        let deviceHubExecutableURL = deviceHubURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(deviceHubExecutable)
        guard fileManager.isExecutableFile(atPath: deviceHubExecutableURL.path) else {
            throw CLIError.unavailable(
                "device-hub-executable",
                "missing executable at \(deviceHubExecutableURL.path)"
            )
        }

        let deviceHubImplementationURL = deviceHubURL
            .appendingPathComponent(ToolConstants.deviceHubImplementationPath)
        guard fileManager.isExecutableFile(atPath: deviceHubImplementationURL.path) else {
            throw CLIError.unavailable(
                "device-hub-implementation",
                "missing executable at \(deviceHubImplementationURL.path)"
            )
        }
        let deviceHubBinary = try binaryData(
            at: deviceHubImplementationURL,
            identifier: "device-hub-implementation"
        )
        let deviceHubKeyData = Data(ToolConstants.deviceHubPreference.key.utf8)
        guard deviceHubBinary.range(of: deviceHubKeyData) != nil else {
            throw CLIError.unavailable(
                "device-hub-preference-key",
                "Device Hub in Xcode \(xcode.version) build \(xcode.buildVersion) no longer contains the verified preference key"
            )
        }

        let binaryURL = xcode.applicationURL
            .appendingPathComponent(ToolConstants.ideIOSSupportCorePath)
        let binary = try binaryData(at: binaryURL, identifier: "xcode-probe-binary")
        let keyData = Data(ToolConstants.xcodePreference.key.utf8)
        guard binary.range(of: keyData) != nil else {
            throw CLIError.unavailable(
                "xcode-preference-key",
                "Xcode \(xcode.version) build \(xcode.buildVersion) no longer contains the verified preference key"
            )
        }
        return xcode
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

    func legacySimulator(explicitXcodeURL: URL?) throws -> SimulatorInstallation {
        if let explicitXcodeURL {
            return try inspectLegacySimulator(in: explicitXcodeURL)
        }

        let candidates = legacySearchRoots.flatMap { root -> [SimulatorInstallation] in
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            return entries.compactMap { entry in
                guard entry.pathExtension == "app",
                      entry.lastPathComponent.hasPrefix("Xcode")
                else {
                    return nil
                }
                return try? inspectLegacySimulator(in: entry)
            }
        }

        guard let selected = candidates.max(by: { lhs, rhs in
            if lhs.xcode.version != rhs.xcode.version {
                return lhs.xcode.version < rhs.xcode.version
            }
            return lhs.xcode.applicationURL.path < rhs.xcode.applicationURL.path
        }) else {
            throw CLIError.unavailable(
                "legacy-simulator",
                "no validated Xcode 26 Simulator was found; use --legacy-xcode <path>"
            )
        }
        return selected
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

    private func inspectLegacySimulator(in xcodeURL: URL) throws -> SimulatorInstallation {
        let xcode = try inspectXcode(at: xcodeURL.standardizedFileURL)
        guard xcode.version.major == ToolConstants.legacyXcodeMajorVersion else {
            throw CLIError.unavailable(
                "legacy-xcode-version",
                "legacy Simulator must come from Xcode 26, found Xcode \(xcode.version)"
            )
        }

        let simulatorURL = xcode.applicationURL
            .appendingPathComponent(ToolConstants.simulatorPath, isDirectory: true)
        let info = try propertyList(at: simulatorURL.appendingPathComponent("Contents/Info.plist"))
        guard info["CFBundleIdentifier"] as? String == ToolConstants.simulatorBundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let buildVersion = info["CFBundleVersion"] as? String
        else {
            throw CLIError.unavailable(
                "legacy-simulator-bundle",
                "\(simulatorURL.path) is not a valid Simulator application"
            )
        }

        let executableURL = simulatorURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executable)
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw CLIError.unavailable(
                "legacy-simulator-executable",
                "missing executable at \(executableURL.path)"
            )
        }
        try signatureValidator.validateAppleApplication(
            simulatorURL,
            ToolConstants.simulatorBundleIdentifier
        )
        return SimulatorInstallation(
            applicationURL: simulatorURL,
            xcode: xcode,
            version: version,
            buildVersion: buildVersion
        )
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

import Foundation
import Testing

@testable import XcodeSimulatorHost

extension CodeSignatureValidator {
    static let acceptingTestFixtures = CodeSignatureValidator { _, _ in }
}

final class TemporaryTestDirectory {
    let url: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        url = fileManager.temporaryDirectory
            .appendingPathComponent("\(ToolConstants.name)-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? fileManager.removeItem(at: url)
    }
}

final class FakeSystemCommandRunner: CommandRunning {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
    }

    enum FailureTiming {
        case beforeMutation
        case afterMutation
    }

    var domains: [String: [String: Any]] = [:]
    var selectedDeveloperDirectory: URL?
    var failMutationNumbers: Set<Int> = []
    var failExportNumber: Int?
    var failFirstExportAfterMutationCount: Int?
    var failMissingDomainExports = false
    var failDomainListing = false
    var neoHostRuntimeValidationStatus: Int32 = 0
    var neoHostRuntimeValidationError = ""
    var failureTiming: FailureTiming = .beforeMutation
    var beforeRun: ((Call) -> Void)?
    private(set) var calls: [Call] = []
    private(set) var mutationCount = 0
    private var exportCount = 0

    func run(executable: URL, arguments: [String]) throws -> CommandOutput {
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        beforeRun?(call)

        switch executable.path {
        case "/usr/bin/defaults":
            return try runDefaults(arguments)
        case "/usr/bin/xcode-select":
            guard arguments == ["-p"], let selectedDeveloperDirectory else {
                return failure("no selected developer directory")
            }
            return success("\(selectedDeveloperDirectory.path)\n")
        default:
            guard executable.lastPathComponent == "XcodeSimulatorNeoHost",
                  arguments.count == 3,
                  arguments[0] == "--validate-runtime",
                  arguments[1] == "--xcode"
            else {
                throw CLIError.software(
                    "unexpected-test-command",
                    "unexpected command: \(executable.path) \(arguments)"
                )
            }
            return CommandOutput(
                terminationStatus: neoHostRuntimeValidationStatus,
                stdout: Data(),
                stderr: Data(neoHostRuntimeValidationError.utf8)
            )
        }
    }

    func storedBoolean(_ preference: ManagedPreference) -> StoredBoolean {
        guard let raw = domains[preference.domain]?[preference.key] else {
            return .absent
        }
        return StoredBoolean((raw as? NSNumber)?.boolValue ?? false)
    }

    func setStoredValue(_ value: Any?, for preference: ManagedPreference) {
        if let value {
            domains[preference.domain, default: [:]][preference.key] = value
        } else {
            domains[preference.domain]?[preference.key] = nil
        }
    }

    private func runDefaults(_ arguments: [String]) throws -> CommandOutput {
        guard let operation = arguments.first else {
            return failure("missing defaults operation")
        }

        switch operation {
        case "domains":
            guard arguments.count == 1 else {
                return failure("invalid domains arguments")
            }
            if failDomainListing {
                return failure("injected domain listing failure")
            }
            return success(domains.keys.sorted().joined(separator: ", "))

        case "export":
            guard arguments.count == 3, arguments[2] == "-" else {
                return failure("invalid export arguments")
            }
            exportCount += 1
            if failExportNumber == exportCount {
                return failure("injected export failure")
            }
            if failFirstExportAfterMutationCount == mutationCount {
                failFirstExportAfterMutationCount = nil
                return failure("injected post-mutation export failure")
            }
            guard let domain = domains[arguments[1]] else {
                if failMissingDomainExports {
                    return failure("domain does not exist")
                }
                return try exportedDomain([:])
            }
            return try exportedDomain(domain)

        case "write":
            guard arguments.count == 5, arguments[3] == "-bool" else {
                return failure("invalid write arguments")
            }
            mutationCount += 1
            if failMutationNumbers.contains(mutationCount), failureTiming == .beforeMutation {
                return failure("injected write failure")
            }
            domains[arguments[1], default: [:]][arguments[2]] = arguments[4] == "true"
            if failMutationNumbers.contains(mutationCount), failureTiming == .afterMutation {
                return failure("injected post-write failure")
            }
            return success()

        case "delete":
            guard arguments.count == 3 else {
                return failure("invalid delete arguments")
            }
            mutationCount += 1
            if failMutationNumbers.contains(mutationCount), failureTiming == .beforeMutation {
                return failure("injected delete failure")
            }
            domains[arguments[1]]?[arguments[2]] = nil
            if failMutationNumbers.contains(mutationCount), failureTiming == .afterMutation {
                return failure("injected post-delete failure")
            }
            return success()

        default:
            return failure("unexpected defaults operation")
        }
    }

    private func exportedDomain(_ domain: [String: Any]) throws -> CommandOutput {
        let data = try PropertyListSerialization.data(
            fromPropertyList: domain,
            format: .xml,
            options: 0
        )
        return CommandOutput(terminationStatus: 0, stdout: data, stderr: Data())
    }

    private func success(_ text: String = "") -> CommandOutput {
        CommandOutput(
            terminationStatus: 0,
            stdout: Data(text.utf8),
            stderr: Data()
        )
    }

    private func failure(_ text: String) -> CommandOutput {
        CommandOutput(
            terminationStatus: 1,
            stdout: Data(),
            stderr: Data(text.utf8)
        )
    }
}

@MainActor
final class WorkspaceRecorder {
    struct NeoHostOpen: Equatable {
        let applicationURL: URL
        let xcodeURL: URL
    }

    var runningXcodes: [RunningApplication] = []
    var runningNeoHosts: [RunningApplication] = []
    var runningLegacySimulators: [RunningApplication] = []
    var deviceHubCount = 0
    var neoHostCount = 0
    var legacySimulatorCount = 0
    var terminateDeviceHubsError: (any Error)?
    var terminateNeoHostsError: (any Error)?
    var terminateLegacySimulatorsError: (any Error)?
    var onTerminateDeviceHubs: (() async -> Void)?
    var onTerminateNeoHosts: (() async -> Void)?
    var onTerminateLegacySimulators: (() async -> Void)?
    private(set) var requestedDeviceHubURLs: [URL] = []
    private(set) var requestedNeoHostURLs: [URL] = []
    private(set) var requestedLegacySimulatorURLSets: [[URL]] = []
    var openedNeoHosts: [NeoHostOpen] = []
    var openedLegacySimulators: [URL] = []
    var openNeoHostError: (any Error)?
    var openLegacySimulatorError: (any Error)?
    var onOpenNeoHost: ((NeoHostOpen) async throws -> Void)?
    var onOpenLegacySimulator: ((URL) async throws -> Void)?
    private(set) var events: [String] = []

    var client: WorkspaceClient {
        WorkspaceClient(
            runningXcodes: { self.runningXcodes },
            runningNeoHosts: { self.runningNeoHosts },
            runningLegacySimulators: { self.runningLegacySimulators },
            terminateDeviceHubs: { url in
                self.events.append("terminate-device-hubs")
                self.requestedDeviceHubURLs.append(url)
                await self.onTerminateDeviceHubs?()
                if let terminateDeviceHubsError = self.terminateDeviceHubsError {
                    throw terminateDeviceHubsError
                }
                return self.deviceHubCount
            },
            terminateNeoHosts: { url in
                self.events.append("terminate-neo-hosts")
                self.requestedNeoHostURLs.append(url)
                await self.onTerminateNeoHosts?()
                if let terminateNeoHostsError = self.terminateNeoHostsError {
                    throw terminateNeoHostsError
                }
                return self.neoHostCount
            },
            terminateLegacySimulators: { urls in
                self.events.append("terminate-legacy-simulators")
                self.requestedLegacySimulatorURLSets.append(urls)
                await self.onTerminateLegacySimulators?()
                if let terminateLegacySimulatorsError =
                    self.terminateLegacySimulatorsError
                {
                    throw terminateLegacySimulatorsError
                }
                return self.legacySimulatorCount
            },
            openNeoHost: { applicationURL, xcodeURL in
                self.events.append("open-neo-host")
                let request = NeoHostOpen(
                    applicationURL: applicationURL,
                    xcodeURL: xcodeURL
                )
                self.openedNeoHosts.append(request)
                if let onOpenNeoHost = self.onOpenNeoHost {
                    try await onOpenNeoHost(request)
                }
                if let openNeoHostError = self.openNeoHostError {
                    throw openNeoHostError
                }
                return applicationURL
            },
            openLegacySimulator: { applicationURL in
                self.events.append("open-legacy-simulator")
                self.openedLegacySimulators.append(applicationURL)
                if let onOpenLegacySimulator = self.onOpenLegacySimulator {
                    try await onOpenLegacySimulator(applicationURL)
                }
                if let openLegacySimulatorError = self.openLegacySimulatorError {
                    throw openLegacySimulatorError
                }
                return applicationURL
            }
        )
    }
}

struct InstallationFixture {
    let directory: TemporaryTestDirectory
    let applicationsURL: URL
    let targetXcodeURL: URL
    let legacyXcodeURLs: [URL]
    let commandExecutableURL: URL
    let neoHostURL: URL
    let coreSimulatorFrameworkURL: URL
    let coreDeviceFrameworkURL: URL

    init(
        targetVersion: String = "27.0",
        targetBuild: String = "27A5252f",
        includeHiddenKey: Bool = true,
        includeDeviceHubKey: Bool = true,
        includeNeoHost: Bool = true,
        legacyVersions: [(String, String, String)] = [
            ("Xcode_26.app", "26.6", "17F109"),
        ],
        coreSimulatorXcodeMajorVersion: Int? = nil,
        coreDeviceXcodeMajorVersion: Int? = nil,
        simulatorCoreDevicePluginXcodeMajorVersion: Int? = nil,
        simctlExpectedVersion: String = "1171.6",
        devicectlExpectedVersion: String = "642.15",
        coreSimulatorBundleVersion: String? = nil,
        coreDeviceBundleVersion: String? = nil,
        simulatorCoreDevicePluginBundleVersion: String? = nil
    ) throws {
        directory = try TemporaryTestDirectory()
        applicationsURL = directory.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationsURL,
            withIntermediateDirectories: false
        )
        targetXcodeURL = applicationsURL.appendingPathComponent("Xcode_27.app", isDirectory: true)
        let versionComponents = try ToolVersion(targetVersion).components
        let targetMajor = versionComponents[0]
        let targetMinor = versionComponents.count > 1 ? versionComponents[1] : 0
        let dtXcode = targetMajor * 100 + targetMinor * 10
        try Self.makeTargetXcode(
            at: targetXcodeURL,
            version: targetVersion,
            build: targetBuild,
            includeHiddenKey: includeHiddenKey,
            includeDeviceHubKey: includeDeviceHubKey,
            simctlExpectedVersion: simctlExpectedVersion,
            devicectlExpectedVersion: devicectlExpectedVersion,
            dtXcode: dtXcode
        )

        var legacyXcodeURLs: [URL] = []
        for entry in legacyVersions {
            let url = applicationsURL.appendingPathComponent(
                entry.0,
                isDirectory: true
            )
            try Self.makeLegacyXcode(
                at: url,
                version: entry.1,
                build: entry.2
            )
            legacyXcodeURLs.append(url)
        }
        self.legacyXcodeURLs = legacyXcodeURLs

        coreSimulatorFrameworkURL = directory.url.appendingPathComponent(
            "Library/Developer/PrivateFrameworks/CoreSimulator.framework",
            isDirectory: true
        )
        let coreMajor = coreSimulatorXcodeMajorVersion ?? targetMajor
        try Self.makeFramework(
            at: coreSimulatorFrameworkURL,
            bundleIdentifier: ToolConstants.coreSimulatorBundleIdentifier,
            executable: "CoreSimulator",
            dtXcode: coreMajor * 100,
            bundleVersion: coreSimulatorBundleVersion ?? simctlExpectedVersion,
            binaryContent: ["fixture-core-simulator"]
        )
        let simctlBinaryURL = coreSimulatorFrameworkURL.appendingPathComponent(
            ToolConstants.simctlBinaryPath
        )
        try Self.writeExecutable(
            content: "fixture-simctl",
            to: simctlBinaryURL
        )

        coreDeviceFrameworkURL = directory.url.appendingPathComponent(
            "Library/Developer/PrivateFrameworks/CoreDevice.framework",
            isDirectory: true
        )
        let coreDeviceMajor = coreDeviceXcodeMajorVersion ?? targetMajor
        try Self.makeFramework(
            at: coreDeviceFrameworkURL,
            bundleIdentifier: ToolConstants.coreDeviceBundleIdentifier,
            executable: "CoreDevice",
            dtXcode: coreDeviceMajor * 100,
            bundleVersion: coreDeviceBundleVersion ?? devicectlExpectedVersion,
            binaryContent: ["fixture-core-device"]
        )
        let devicectlBinaryURL = coreDeviceFrameworkURL.appendingPathComponent(
            ToolConstants.devicectlBinaryPath
        )
        try Self.writeExecutable(
            content: "fixture-devicectl",
            to: devicectlBinaryURL
        )
        let simulatorCoreDevicePluginURL = coreDeviceFrameworkURL
            .appendingPathComponent(
                ToolConstants.simulatorCoreDevicePluginPath,
                isDirectory: true
            )
        try Self.makeSimulatorCoreDevicePlugin(
            at: simulatorCoreDevicePluginURL,
            dtXcode: (simulatorCoreDevicePluginXcodeMajorVersion ?? targetMajor)
                * 100,
            bundleVersion: simulatorCoreDevicePluginBundleVersion
                ?? simctlExpectedVersion
        )

        commandExecutableURL = directory.url.appendingPathComponent(
            "prefix/bin/\(ToolConstants.name)"
        )
        try Self.writeExecutable(
            content: "fixture-command",
            to: commandExecutableURL
        )
        neoHostURL = directory.url.appendingPathComponent(
            "prefix/libexec/xcode-simulator-host/XcodeSimulatorNeoHost.app",
            isDirectory: true
        )
        if includeNeoHost {
            try Self.makeNeoHost(at: neoHostURL)
        }
    }

    var developerDirectoryURL: URL {
        targetXcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true)
    }

    var legacySimulatorURLs: [URL] {
        legacyXcodeURLs.map {
            $0.appendingPathComponent(ToolConstants.simulatorPath, isDirectory: true)
        }
    }

    var simctlWrapperURL: URL {
        targetXcodeURL.appendingPathComponent(ToolConstants.simctlWrapperPath)
    }

    var devicectlWrapperURL: URL {
        targetXcodeURL.appendingPathComponent(ToolConstants.devicectlWrapperPath)
    }

    var simctlBinaryURL: URL {
        coreSimulatorFrameworkURL.appendingPathComponent(
            ToolConstants.simctlBinaryPath
        )
    }

    var devicectlBinaryURL: URL {
        coreDeviceFrameworkURL.appendingPathComponent(
            ToolConstants.devicectlBinaryPath
        )
    }

    var simulatorCoreDevicePluginURL: URL {
        coreDeviceFrameworkURL.appendingPathComponent(
            ToolConstants.simulatorCoreDevicePluginPath,
            isDirectory: true
        )
    }

    var simulatorCoreDevicePluginBinaryURL: URL {
        simulatorCoreDevicePluginURL.appendingPathComponent(
            "Contents/MacOS/SimulatorCoreDevicePlugin"
        )
    }

    var neoHostExecutableURL: URL {
        neoHostURL.appendingPathComponent(
            "Contents/MacOS/XcodeSimulatorNeoHost"
        )
    }

    static func makeTargetXcode(
        at url: URL,
        version: String,
        build: String,
        includeHiddenKey: Bool,
        includeDeviceHubKey: Bool,
        simctlExpectedVersion: String,
        devicectlExpectedVersion: String,
        dtXcode: Int
    ) throws {
        try makeXcodeBase(at: url, version: version, build: build)

        try writeExecutable(
            content: "#!/bin/bash\nEXPECTED_VERSION=\"\(simctlExpectedVersion)\"\n",
            to: url.appendingPathComponent(ToolConstants.simctlWrapperPath)
        )
        try writeExecutable(
            content: "#!/bin/zsh\nEXPECTED_VERSION=\"\(devicectlExpectedVersion)\"\n",
            to: url.appendingPathComponent(ToolConstants.devicectlWrapperPath)
        )

        let deviceHubURL = url.appendingPathComponent(ToolConstants.deviceHubPath, isDirectory: true)
        try writePropertyList(
            [
                "CFBundleIdentifier": ToolConstants.deviceHubBundleIdentifier,
                "CFBundleExecutable": "DevicesTrampoline",
            ],
            to: deviceHubURL.appendingPathComponent("Contents/Info.plist")
        )
        let deviceHubExecutableURL = deviceHubURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("DevicesTrampoline")
        try FileManager.default.createDirectory(
            at: deviceHubExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: deviceHubExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: deviceHubExecutableURL.path
        )
        let deviceHubImplementationURL = deviceHubURL
            .appendingPathComponent(ToolConstants.deviceHubImplementationPath)
        let deviceHubContent = includeDeviceHubKey
            ? "prefix\(ToolConstants.deviceHubPreference.key)suffix"
            : "missing-key"
        try Data(deviceHubContent.utf8).write(to: deviceHubImplementationURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: deviceHubImplementationURL.path
        )

        let binaryURL = url.appendingPathComponent(ToolConstants.ideIOSSupportCorePath)
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = includeHiddenKey
            ? "prefix\(ToolConstants.xcodePreference.key)suffix"
            : "missing-key"
        try Data(content.utf8).write(to: binaryURL)

        try makeFramework(
            at: url.appendingPathComponent(
                ToolConstants.simulatorKitPath,
                isDirectory: true
            ),
            bundleIdentifier: ToolConstants.simulatorKitBundleIdentifier,
            executable: "SimulatorKit",
            dtXcode: dtXcode,
            bundleVersion: String(dtXcode),
            binaryContent: ["fixture-simulator-kit"]
        )
        try makeFramework(
            at: url.appendingPathComponent(
                ToolConstants.idePlaygroundSimulatorPath,
                isDirectory: true
            ),
            bundleIdentifier: ToolConstants.idePlaygroundSimulatorBundleIdentifier,
            executable: "IDEPlaygroundSimulator",
            dtXcode: dtXcode,
            bundleVersion: String(dtXcode),
            binaryContent: ["fixture-ide-playground-simulator"]
        )
    }

    static func makeLegacyXcode(
        at url: URL,
        version: String,
        build: String
    ) throws {
        try makeXcodeBase(at: url, version: version, build: build)

        let versionComponents = try ToolVersion(version).components
        let minor = versionComponents.count > 1 ? versionComponents[1] : 0
        let dtXcode = versionComponents[0] * 100 + minor * 10
        let simulatorURL = url.appendingPathComponent(
            ToolConstants.simulatorPath,
            isDirectory: true
        )
        try writePropertyList(
            [
                "CFBundleIdentifier": ToolConstants.simulatorBundleIdentifier,
                "CFBundleExecutable": "Simulator",
                "CFBundleShortVersionString": "16.0",
                "CFBundleVersion": "1063.4",
                "DTXcode": String(dtXcode),
            ],
            to: simulatorURL.appendingPathComponent("Contents/Info.plist")
        )
        try writeExecutable(
            content: "fixture-simulator",
            to: simulatorURL.appendingPathComponent("Contents/MacOS/Simulator")
        )
    }

    private static func makeXcodeBase(at url: URL, version: String, build: String) throws {
        try writePropertyList(
            [
                "CFBundleIdentifier": ToolConstants.xcodeBundleIdentifier,
                "CFBundleShortVersionString": version,
            ],
            to: url.appendingPathComponent("Contents/Info.plist")
        )
        try writePropertyList(
            ["ProductBuildVersion": build],
            to: url.appendingPathComponent("Contents/version.plist")
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents/Developer", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private static func makeFramework(
        at url: URL,
        bundleIdentifier: String,
        executable: String,
        dtXcode: Int,
        bundleVersion: String,
        binaryContent: [String]
    ) throws {
        try writePropertyList(
            [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": executable,
                "CFBundleVersion": bundleVersion,
                "DTXcode": String(dtXcode),
                "DTXcodeBuild": "fixture-build",
            ],
            to: url.appendingPathComponent("Versions/A/Resources/Info.plist")
        )
        try writeExecutable(
            content: binaryContent.joined(separator: "\n"),
            to: url.appendingPathComponent("Versions/A/\(executable)")
        )
    }

    private static func makeSimulatorCoreDevicePlugin(
        at url: URL,
        dtXcode: Int,
        bundleVersion: String
    ) throws {
        try writePropertyList(
            [
                "CFBundleIdentifier": ToolConstants.simulatorCoreDevicePluginBundleIdentifier,
                "CFBundleExecutable": "SimulatorCoreDevicePlugin",
                "CFBundleVersion": bundleVersion,
                "DTXcode": String(dtXcode),
            ],
            to: url.appendingPathComponent("Contents/Info.plist")
        )
        try writeExecutable(
            content: "fixture-simulator-core-device-plugin",
            to: url.appendingPathComponent(
                "Contents/MacOS/SimulatorCoreDevicePlugin"
            )
        )
    }

    private static func makeNeoHost(at url: URL) throws {
        try writePropertyList(
            [
                "CFBundleIdentifier": ToolConstants.neoHostBundleIdentifier,
                "CFBundleExecutable": "XcodeSimulatorNeoHost",
            ],
            to: url.appendingPathComponent("Contents/Info.plist")
        )
        try writeExecutable(
            content: "fixture-host",
            to: url.appendingPathComponent(
                "Contents/MacOS/XcodeSimulatorNeoHost"
            )
        )
    }

    private static func writeExecutable(content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func writePropertyList(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}

@MainActor
struct ControllerFixture {
    let installations: InstallationFixture
    let stateDirectory: TemporaryTestDirectory
    let runner: FakeSystemCommandRunner
    let workspace: WorkspaceRecorder
    let receiptStore: ReceiptStore
    let controller: HostModeController

    init(
        initialState: ManagedPreferenceState = .deviceHub,
        targetVersion: String = "27.0",
        includeHiddenKey: Bool = true,
        includeNeoHost: Bool = true,
        neoHostRuntimeValidationStatus: Int32 = 0,
        effectiveUserID: uid_t = 501
    ) throws {
        installations = try InstallationFixture(
            targetVersion: targetVersion,
            includeHiddenKey: includeHiddenKey,
            includeNeoHost: includeNeoHost
        )
        stateDirectory = try TemporaryTestDirectory()
        runner = FakeSystemCommandRunner()
        runner.neoHostRuntimeValidationStatus = neoHostRuntimeValidationStatus
        if neoHostRuntimeValidationStatus != 0 {
            runner.neoHostRuntimeValidationError =
                "injected private runtime validation failure"
        }
        runner.selectedDeveloperDirectory = installations.developerDirectoryURL
        runner.setStoredValue(
            initialState.xcodeSession.booleanValue,
            for: ToolConstants.xcodePreference
        )
        runner.setStoredValue(
            initialState.deviceHubAutoStartSuppression.booleanValue,
            for: ToolConstants.deviceHubPreference
        )
        workspace = WorkspaceRecorder()
        receiptStore = try ReceiptStore(
            directoryURL: stateDirectory.url.appendingPathComponent(
                "state",
                isDirectory: true
            )
        )

        let inspector = InstallationInspector(
            runner: runner,
            environment: ["DEVELOPER_DIR": installations.developerDirectoryURL.path],
            legacySearchRoots: [installations.applicationsURL],
            commandExecutableURL: installations.commandExecutableURL,
            coreSimulatorFrameworkURL: installations.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: installations.coreDeviceFrameworkURL,
            signatureValidator: .acceptingTestFixtures
        )
        controller = HostModeController(
            defaultsStore: DefaultsStore(runner: runner),
            receiptStore: receiptStore,
            installationInspector: inspector,
            workspace: workspace.client,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            effectiveUserID: effectiveUserID
        )
    }
}

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

final class FakeSystemCommandRunner: CommandRunning, PreferenceDomainAccessing {
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
    var failPreferenceReadNumber: Int?
    var failFirstPreferenceReadAfterMutationCount: Int?
    var failPreferenceReads = false
    var neoHostRuntimeValidationStatus: Int32 = 0
    var neoHostRuntimeValidationOutput = ""
    var neoHostRuntimeValidationError = ""
    var failureTiming: FailureTiming = .beforeMutation
    var beforeRun: ((Call) -> Void)?
    private(set) var calls: [Call] = []
    private(set) var mutationCount = 0
    private var preferenceReadCount = 0

    func run(executable: URL, arguments: [String]) throws -> CommandOutput {
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        beforeRun?(call)

        switch executable.path {
        case "/usr/bin/xcode-select":
            guard arguments == ["-p"], let selectedDeveloperDirectory else {
                return failure("no selected developer directory")
            }
            return success("\(selectedDeveloperDirectory.path)\n")
        default:
            guard executable.lastPathComponent == "NeoSimulator",
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
                stdout: Data(neoHostRuntimeValidationOutput.utf8),
                stderr: Data(neoHostRuntimeValidationError.utf8)
            )
        }
    }

    func readDomain(_ domain: String, keys: [String]) throws -> [String: Any] {
        recordPreferenceAccess(["read", domain])
        if failPreferenceReads { throw CLIError.io("preference-read", "injected domain read failure") }
        guard let values = domains[domain] else { return [:] }
        preferenceReadCount += 1
        if failPreferenceReadNumber == preferenceReadCount {
            throw CLIError.io("preference-read", "injected read failure")
        }
        if failFirstPreferenceReadAfterMutationCount == mutationCount {
            failFirstPreferenceReadAfterMutationCount = nil
            throw CLIError.io("preference-read", "injected post-mutation read failure")
        }
        return values.filter { keys.contains($0.key) }
    }

    func write(_ value: StoredBoolean, to preference: ManagedPreference) throws {
        recordPreferenceAccess(["write", preference.domain, preference.key])
        mutationCount += 1
        if failMutationNumbers.contains(mutationCount), failureTiming == .beforeMutation {
            throw CLIError.io("preference-write", "injected write failure")
        }
        setStoredValue(value.booleanValue, for: preference)
        if failMutationNumbers.contains(mutationCount), failureTiming == .afterMutation {
            throw CLIError.io("preference-write", "injected post-write failure")
        }
    }

    private func recordPreferenceAccess(_ arguments: [String]) {
        let call = Call(executable: URL(fileURLWithPath: "/usr/bin/defaults"), arguments: arguments)
        calls.append(call)
        beforeRun?(call)
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
    var deviceHubCount = 0
    var neoHostCount = 0
    var terminateDeviceHubsError: (any Error)?
    var terminateNeoHostsError: (any Error)?
    var onTerminateDeviceHubs: (() async -> Void)?
    var onTerminateNeoHosts: (() async -> Void)?
    private(set) var requestedDeviceHubURLs: [URL] = []
    private(set) var requestedNeoHostURLs: [URL] = []
    var openedNeoHosts: [NeoHostOpen] = []
    var openedDeviceHubs: [URL] = []
    var openDeviceHubError: (any Error)?
    var openNeoHostError: (any Error)?
    var onOpenNeoHost: ((NeoHostOpen) async throws -> Void)?
    private(set) var events: [String] = []

    var client: WorkspaceClient {
        WorkspaceClient(
            runningXcodes: { self.runningXcodes },
            runningNeoHosts: { self.runningNeoHosts },
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
            openNeoHost: { applicationURL, xcodeURL, _ in
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
            openDeviceHub: { applicationURL in
                self.events.append("open-device-hub")
                self.openedDeviceHubs.append(applicationURL)
                if let error = self.openDeviceHubError { throw error }
                return applicationURL
            },
            quitNeoHost: { _, _, _ in self.neoHostCount }

        )
    }
}

struct InstallationFixture {
    let directory: TemporaryTestDirectory
    let applicationsURL: URL
    let targetXcodeURL: URL
    let neoHostURL: URL
    let coreSimulatorFrameworkURL: URL
    let coreDeviceFrameworkURL: URL

    init(
        targetVersion: String = "27.0",
        targetBuild: String = "27A5252f",
        includeHiddenKey: Bool = true,
        includeDeviceHubKey: Bool = true,
        includeNeoHost: Bool = true,
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

        neoHostURL = directory.url.appendingPathComponent(
            "prefix/Applications/NeoSimulatorRenderer.app",
            isDirectory: true
        )
        if includeNeoHost {
            try Self.makeNeoHost(at: neoHostURL)
        }
    }

    var developerDirectoryURL: URL {
        targetXcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true)
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
            "Contents/MacOS/NeoSimulator"
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
        try Data("fixture-device-hub".utf8).write(to: deviceHubImplementationURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: deviceHubImplementationURL.path
        )

        try makeFramework(
            at: url.appendingPathComponent(ToolConstants.deviceKitPath, isDirectory: true),
            bundleIdentifier: ToolConstants.deviceKitBundleIdentifier,
            executable: "DeviceKit",
            dtXcode: dtXcode,
            bundleVersion: "1",
            binaryContent: [includeDeviceHubKey ? ToolConstants.deviceHubPreference.key : "missing-key"]
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
                "CFBundleExecutable": "NeoSimulator",
            ],
            to: url.appendingPathComponent("Contents/Info.plist")
        )
        try writeExecutable(
            content: "fixture-host",
            to: url.appendingPathComponent(
                "Contents/MacOS/NeoSimulator"
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
        effectiveUserID: uid_t = 501,
        signatureValidator: CodeSignatureValidator = .acceptingTestFixtures
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
            rendererApplicationURL: installations.neoHostURL,
            coreSimulatorFrameworkURL: installations.coreSimulatorFrameworkURL,
            coreDeviceFrameworkURL: installations.coreDeviceFrameworkURL,
            signatureValidator: signatureValidator
        )
        controller = HostModeController(
            defaultsStore: DefaultsStore(domains: runner),
            receiptStore: receiptStore,
            installationInspector: inspector,
            workspace: workspace.client,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            effectiveUserID: effectiveUserID
        )
    }
}

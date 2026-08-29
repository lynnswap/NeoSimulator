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
            throw CLIError.software(
                "unexpected-test-command",
                "unexpected command: \(executable.path) \(arguments)"
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
    struct LegacyHostOpen: Equatable {
        let applicationURL: URL
        let xcodeURL: URL
    }

    var runningXcodes: [RunningApplication] = []
    var runningLegacyHosts: [RunningApplication] = []
    var deviceHubCount = 0
    var legacyHostCount = 0
    var terminateDeviceHubsError: (any Error)?
    var terminateLegacyHostsError: (any Error)?
    var onTerminateDeviceHubs: (() async -> Void)?
    var onTerminateLegacyHosts: (() async -> Void)?
    private(set) var requestedDeviceHubURLs: [URL] = []
    private(set) var requestedLegacyHostURLs: [URL] = []
    var openedLegacyHosts: [LegacyHostOpen] = []
    var openLegacyHostError: (any Error)?
    var onOpenLegacyHost: ((LegacyHostOpen) async throws -> Void)?
    private(set) var events: [String] = []

    var client: WorkspaceClient {
        WorkspaceClient(
            runningXcodes: { self.runningXcodes },
            runningLegacyHosts: { self.runningLegacyHosts },
            terminateDeviceHubs: { url in
                self.events.append("terminate-device-hubs")
                self.requestedDeviceHubURLs.append(url)
                await self.onTerminateDeviceHubs?()
                if let terminateDeviceHubsError = self.terminateDeviceHubsError {
                    throw terminateDeviceHubsError
                }
                return self.deviceHubCount
            },
            terminateLegacyHosts: { url in
                self.events.append("terminate-legacy-hosts")
                self.requestedLegacyHostURLs.append(url)
                await self.onTerminateLegacyHosts?()
                if let terminateLegacyHostsError = self.terminateLegacyHostsError {
                    throw terminateLegacyHostsError
                }
                return self.legacyHostCount
            },
            openLegacyHost: { applicationURL, xcodeURL in
                self.events.append("open-legacy-host")
                let request = LegacyHostOpen(
                    applicationURL: applicationURL,
                    xcodeURL: xcodeURL
                )
                self.openedLegacyHosts.append(request)
                if let onOpenLegacyHost = self.onOpenLegacyHost {
                    try await onOpenLegacyHost(request)
                }
                if let openLegacyHostError = self.openLegacyHostError {
                    throw openLegacyHostError
                }
                return applicationURL
            }
        )
    }
}

struct InstallationFixture {
    let directory: TemporaryTestDirectory
    let targetXcodeURL: URL
    let commandExecutableURL: URL
    let legacyHostURL: URL
    let coreSimulatorFrameworkURL: URL

    init(
        targetVersion: String = "27.0",
        targetBuild: String = "27A5252f",
        includeHiddenKey: Bool = true,
        includeDeviceHubKey: Bool = true,
        includeSimulatorKitSurface: Bool = true,
        includeIDEPlaygroundSimulatorSurface: Bool = true,
        includeCoreSimulatorSurface: Bool = true,
        includeLegacyHost: Bool = true,
        coreSimulatorXcodeMajorVersion: Int? = nil
    ) throws {
        directory = try TemporaryTestDirectory()
        let applicationsURL = directory.url.appendingPathComponent(
            "Applications",
            isDirectory: true
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
            includeSimulatorKitSurface: includeSimulatorKitSurface,
            includeIDEPlaygroundSimulatorSurface: includeIDEPlaygroundSimulatorSurface,
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
            binaryContent: includeCoreSimulatorSurface
                ? [
                    "SimServiceContext",
                    "sharedServiceContextForDeveloperDir:error:",
                    "defaultDeviceSetWithError:",
                    "availableDevices",
                    "registerNotificationHandlerOnQueue:handler:",
                ]
                : ["missing-core-surface"]
        )

        commandExecutableURL = directory.url.appendingPathComponent(
            "prefix/bin/\(ToolConstants.name)"
        )
        try Self.writeExecutable(
            content: "fixture-command",
            to: commandExecutableURL
        )
        legacyHostURL = directory.url.appendingPathComponent(
            "prefix/libexec/xcode-simulator-host/XcodeSimulatorLegacyHost.app",
            isDirectory: true
        )
        if includeLegacyHost {
            try Self.makeLegacyHost(at: legacyHostURL)
        }
    }

    var developerDirectoryURL: URL {
        targetXcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true)
    }

    static func makeTargetXcode(
        at url: URL,
        version: String,
        build: String,
        includeHiddenKey: Bool,
        includeDeviceHubKey: Bool,
        includeSimulatorKitSurface: Bool,
        includeIDEPlaygroundSimulatorSurface: Bool,
        dtXcode: Int
    ) throws {
        try makeXcodeBase(at: url, version: version, build: build)

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
            binaryContent: includeSimulatorKitSurface
                ? [
                    "_TtC12SimulatorKit14SimDisplayView",
                    "_TtC12SimulatorKit15SimDeviceScreen",
                    "_TtC12SimulatorKit24SimDeviceLegacyHIDClient",
                    "isDefault",
                    "IndigoHIDMessageForButton",
                ]
                : ["missing-simulator-kit-surface"]
        )
        try makeFramework(
            at: url.appendingPathComponent(
                ToolConstants.idePlaygroundSimulatorPath,
                isDirectory: true
            ),
            bundleIdentifier: ToolConstants.idePlaygroundSimulatorBundleIdentifier,
            executable: "IDEPlaygroundSimulator",
            dtXcode: dtXcode,
            binaryContent: includeIDEPlaygroundSimulatorSurface
                ? [
                    "_TtC22IDEPlaygroundSimulator27IDESimulatorPlaygroundUntil",
                    "createSimDisplayViewWithDevice:simScreenID:",
                ]
                : ["missing-ide-playground-surface"]
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
        binaryContent: [String]
    ) throws {
        try writePropertyList(
            [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": executable,
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

    private static func makeLegacyHost(at url: URL) throws {
        try writePropertyList(
            [
                "CFBundleIdentifier": ToolConstants.legacyHostBundleIdentifier,
                "CFBundleExecutable": "XcodeSimulatorLegacyHost",
            ],
            to: url.appendingPathComponent("Contents/Info.plist")
        )
        try writeExecutable(
            content: "fixture-host",
            to: url.appendingPathComponent(
                "Contents/MacOS/XcodeSimulatorLegacyHost"
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
        includeLegacyHost: Bool = true,
        effectiveUserID: uid_t = 501
    ) throws {
        installations = try InstallationFixture(
            targetVersion: targetVersion,
            includeHiddenKey: includeHiddenKey,
            includeLegacyHost: includeLegacyHost
        )
        stateDirectory = try TemporaryTestDirectory()
        runner = FakeSystemCommandRunner()
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
            commandExecutableURL: installations.commandExecutableURL,
            coreSimulatorFrameworkURL: installations.coreSimulatorFrameworkURL,
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

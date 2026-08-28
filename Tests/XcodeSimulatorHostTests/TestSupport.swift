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
    var runningXcodes: [RunningApplication] = []
    var deviceHubCount = 0
    var terminateDeviceHubsError: (any Error)?
    var onTerminateDeviceHubs: (() async -> Void)?
    private(set) var requestedDeviceHubURLs: [URL] = []
    var openedApplications: [URL] = []
    var openError: (any Error)?
    var onOpenApplication: ((URL) async throws -> Void)?
    private(set) var events: [String] = []

    var client: WorkspaceClient {
        WorkspaceClient(
            runningXcodes: { self.runningXcodes },
            terminateDeviceHubs: { url in
                self.events.append("terminate-device-hubs")
                self.requestedDeviceHubURLs.append(url)
                await self.onTerminateDeviceHubs?()
                if let terminateDeviceHubsError = self.terminateDeviceHubsError {
                    throw terminateDeviceHubsError
                }
                return self.deviceHubCount
            },
            openApplication: { url in
                self.events.append("open-simulator")
                self.openedApplications.append(url)
                if let onOpenApplication = self.onOpenApplication {
                    try await onOpenApplication(url)
                }
                if let openError = self.openError {
                    throw openError
                }
                return url
            }
        )
    }
}

struct InstallationFixture {
    let directory: TemporaryTestDirectory
    let applicationsURL: URL
    let targetXcodeURL: URL
    let legacyXcodeURL: URL

    init(
        targetVersion: String = "27.0",
        targetBuild: String = "27A5252f",
        includeHiddenKey: Bool = true,
        includeDeviceHubKey: Bool = true,
        legacyVersions: [(String, String, String)] = [
            ("Xcode.app", "26.6", "17F109"),
        ]
    ) throws {
        directory = try TemporaryTestDirectory()
        applicationsURL = directory.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationsURL,
            withIntermediateDirectories: false
        )

        targetXcodeURL = applicationsURL.appendingPathComponent("Xcode_27.app", isDirectory: true)
        try Self.makeTargetXcode(
            at: targetXcodeURL,
            version: targetVersion,
            build: targetBuild,
            includeHiddenKey: includeHiddenKey,
            includeDeviceHubKey: includeDeviceHubKey
        )

        var legacyURLs: [URL] = []
        for entry in legacyVersions {
            let url = applicationsURL.appendingPathComponent(entry.0, isDirectory: true)
            try Self.makeLegacyXcode(at: url, version: entry.1, build: entry.2)
            legacyURLs.append(url)
        }
        guard let first = legacyURLs.first else {
            throw CLIError.software("test-fixture", "legacy fixture requires one Xcode")
        }
        legacyXcodeURL = first
    }

    var developerDirectoryURL: URL {
        targetXcodeURL.appendingPathComponent("Contents/Developer", isDirectory: true)
    }

    static func makeTargetXcode(
        at url: URL,
        version: String,
        build: String,
        includeHiddenKey: Bool,
        includeDeviceHubKey: Bool
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
    }

    static func makeLegacyXcode(at url: URL, version: String, build: String) throws {
        try makeXcodeBase(at: url, version: version, build: build)

        let versionComponents = try ToolVersion(version).components
        let minor = versionComponents.count > 1 ? versionComponents[1] : 0
        let dtXcode = versionComponents[0] * 100 + minor * 10

        let simulatorURL = url.appendingPathComponent(ToolConstants.simulatorPath, isDirectory: true)
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
        let executableURL = simulatorURL.appendingPathComponent("Contents/MacOS/Simulator")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
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
        effectiveUserID: uid_t = 501
    ) throws {
        installations = try InstallationFixture(
            targetVersion: targetVersion,
            includeHiddenKey: includeHiddenKey
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
            legacySearchRoots: [installations.applicationsURL],
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

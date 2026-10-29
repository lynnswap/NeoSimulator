import Foundation
import Testing
@testable import XcodeSimulatorHost

@Suite struct DeviceInspectorTests {
    @Test func integerValuesPreserveUnsignedJSONAndPropertyListPrecision() throws {
        let raw: UInt64 = 18446744071562067970
        let json = try JSONDecoder().decode(DeviceInspectorValue.self, from: Data(#"{"unsigned":18446744071562067970,"signed":-2,"fraction":0.5,"flag":true}"#.utf8))
        #expect(json["unsigned"] == .unsignedInteger(raw))
        #expect(json["signed"] == .integer(-2) && json["fraction"] == .number(0.5))
        #expect(json["flag"] == .boolean(true))
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "unsigned": NSNumber(value: raw), "flag": NSNumber(value: true), "zero": NSNumber(value: 0), "one": NSNumber(value: 1),
        ], format: .binary, options: 0)
        let plist = try DeviceInspectorValue.propertyList(PropertyListSerialization.propertyList(from: data, format: nil))
        #expect(plist["unsigned"] == .unsignedInteger(raw) && plist["flag"] == .boolean(true))
        #expect(plist["zero"] == .integer(0) && plist["one"] == .integer(1))
        #expect(plist["zero"]?.boolean == false && plist["one"]?.boolean == true)
        #expect(DeviceInspectorValue.unsignedInteger(0).boolean == false && DeviceInspectorValue.unsignedInteger(1).boolean == true)
    }

    @Test func simulatorInfoUsesItsCatalogModelAndCompleteRuntimeVersion() async {
        let calls = InspectorCalls { _ in Self.output(#"""
        {"devices":{"runtime":[{"udid":"sim-udid","name":"Renamed Phone","deviceTypeIdentifier":"phone-type","dataPath":"/guest/Data"}]},
         "devicetypes":[{"identifier":"phone-type","name":"iPhone 16e"}],
         "runtimes":[{"identifier":"runtime","name":"iOS 18.3","version":"18.3.1"}]}
        """#) }
        let snapshot = await Self.simulator(transport: .init(run: { try await calls.run($0) })).info()
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.fields["modelName"] == .string("iPhone 16e"))
        #expect(snapshot.fields["operatingSystem"] == .string("iOS 18.3.1"))
        #expect(snapshot.fields["dataPath"] == .string("/guest/Data"))
    }

    @Test func simulatorPlistAppsKeepIdentityVersionsFlagsAndCustomSet() async throws {
        let calls = InspectorCalls { _ in Self.output(#"""
        {"dev.example.fixture" = { CFBundleIdentifier = "dev.example.fixture"; CFBundleDisplayName = "Fixture App";
          CFBundleShortVersionString = "1.2"; CFBundleVersion = "10"; Path = "/guest/Fixture.app";
          DataContainer = "file:///guest/Data/"; IsDeveloperApp = 1; IsRemovable = 0;
          GroupContainers = { "group.fixture" = "file:///guest/Group/"; }; };}
        """#) }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        let app = try #require(try await inspector.applications().first)
        #expect(app.bundleIdentifier == "dev.example.fixture" && app.name == "Fixture App")
        #expect(app.version == "1.2" && app.build == "10")
        #expect(app.isDeveloperApplication == true && app.isRemovable == false)
        #expect(app.groupContainerPaths["group.fixture"] == "/guest/Group")
        let command = try #require(await calls.commands.first)
        #expect(command.source == .simulator(xcodeURL: Self.xcode, deviceSetPath: "/fixture-device-set"))
        #expect(command.arguments == ["listapps", "sim-udid"])
    }

    @Test func remoteApplicationsAndProfileMetadataUseCoreDeviceIdentity() async throws {
        let calls = InspectorCalls { command in
            if command.arguments.starts(with: ["device", "info", "apps"]) { return Self.output(Self.apps) }
            return Self.output(Self.profiles)
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let app = try await inspector.application(bundleIdentifier: "dev.example.app")
        #expect(app.name == "Remote App" && app.version == "2.0" && app.build == "42")
        #expect(app.dataContainerPath == "/private/remote/Data" && app.isContainerAccessible)
        let snapshot = try await inspector.profiles()
        #expect(snapshot.profiles.count == 2)
        let config = try #require(snapshot.profiles.first { $0.kind == .configuration })
        #expect(config.identifier == "dev.example.configuration" && config.uuid == "profile-uuid")
        #expect(config.metadata["payloadTypes"]?.array == [.string("com.apple.wifi.managed")])
        #expect(snapshot.partialProvisioningProfiles == [.object(["identifier": .string("partial-profile")])])
        try await inspector.removeProfile(identifier: config.identifier, kind: config.kind)
        let commands = await calls.commands
        #expect(commands.allSatisfy { $0.source == .coreDevice && $0.arguments.contains("core-command-id") && !$0.arguments.contains("hardware-udid") })
        let removal = try #require(commands.last)
        #expect(removal.arguments.starts(with: ["device", "profile", "remove", "dev.example.configuration", "--type", "configuration"]))
    }

    @Test func failureRetainsSourceTargetDiagnosticsAndKnownInfo() async throws {
        let calls = InspectorCalls { _ in
            CommandOutput(terminationStatus: 65, stdout: Data("partial operation response".utf8), stderr: Data("device disconnected".utf8))
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let snapshot = await inspector.info()
        #expect(snapshot.deviceID == .coreDevice("core-command-id") && snapshot.device.name == "Remote Phone")
        #expect(snapshot.fields.isEmpty)
        let issue = try #require(snapshot.issues.first)
        #expect(issue.deviceID == .coreDevice("core-command-id") && issue.source == .coreDevice)
        guard case .commandFailed(let status, let stdout, let stderr) = issue.error as? DeviceInspectorError else { Issue.record("Lost original command diagnostics"); return }
        #expect(status == 65 && stdout == "partial operation response" && stderr == "device disconnected")
    }

    @Test func configurationProfileQueriesDoNotRequestUnsupportedProvisioningProfiles() async throws {
        let calls = InspectorCalls { command in
            guard command.arguments.starts(with: ["device", "profile", "list", "--type", "configuration"]) else {
                return CommandOutput(terminationStatus: 1, stdout: Data(), stderr: Data("Provisioning profiles are unsupported".utf8))
            }
            return Self.output(Self.profiles)
        }
        let transport = DeviceInspectorTransport(run: { try await calls.run($0) })
        let simulator = Self.simulator(deviceSetPath: nil, transport: transport)
        let simulatorProfiles = try await simulator.profiles()
        #expect(simulatorProfiles.profiles.map(\.kind) == [.configuration])
        let remote = try Self.remote(transport: transport)
        let configuration = try await remote.profiles(kind: .configuration)
        #expect(configuration.profiles.map(\.kind) == [.configuration])
        #expect(configuration.partialProvisioningProfiles.isEmpty)
        let profile = try await remote.profile(identifier: "dev.example.configuration", kind: .configuration)
        #expect(profile.identifier == "dev.example.configuration")
        #expect(await calls.commands.count == 3)
    }

    @Test func remoteFinderPathIsNotMistakenForALocalFile() async throws {
        let calls = InspectorCalls { _ in Self.output(Self.apps) }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        do {
            _ = try await inspector.applicationContainerURL(bundleIdentifier: "dev.example.app")
            Issue.record("A remote path was returned as a Mac container URL")
        } catch let error as DeviceInspectorFailure {
            #expect(error.deviceID == .coreDevice("core-command-id"))
            #expect(error.error is DeviceInspectorError)
        }
        #expect(await calls.commands.isEmpty)
    }

    @Test func packageRoundTripPreservesContentsAndContainerIdentityAndRemovesStaleData() async throws {
        let directory = try TemporaryTestDirectory()
        let container = directory.url.appendingPathComponent("Container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let identity = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        try Data("original identity".utf8).write(to: identity)
        for name in ["Documents", "Library", "tmp"] {
            let child = container.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            try Data(name.utf8).write(to: child.appendingPathComponent("fixture"))
        }
        let calls = InspectorCalls { command in
            if command.arguments.first == "get_app_container" { return Self.output(container.path) }
            return CommandOutput(terminationStatus: 3, stdout: Data(), stderr: Data("not running".utf8))
        }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        let package = directory.url.appendingPathComponent("Fixture.xcappdata", isDirectory: true)
        try await inspector.downloadApplicationData(bundleIdentifier: "dev.example.app", to: package)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("AppData/.com.apple.mobile_container_manager.metadata.plist").path))
        try Data("stale".utf8).write(to: container.appendingPathComponent("stale"))
        try Data("changed".utf8).write(to: container.appendingPathComponent("Documents/fixture"))
        try await inspector.replaceApplicationData(bundleIdentifier: "dev.example.app", from: package)
        #expect(try String(contentsOf: identity, encoding: .utf8) == "original identity")
        #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("stale").path))
        for name in ["Documents", "Library", "tmp"] {
            #expect(try String(contentsOf: container.appendingPathComponent("\(name)/fixture"), encoding: .utf8) == name)
        }
    }

    @Test func invalidReplacementAndExistingExportDoNotTouchCurrentData() async throws {
        let directory = try TemporaryTestDirectory()
        let marker = directory.url.appendingPathComponent("keep")
        try Data("preserved".utf8).write(to: marker)
        let path = directory.url.path
        let calls = InspectorCalls { _ in Self.output(path) }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        do {
            try await inspector.replaceApplicationData(bundleIdentifier: "dev.example.app", from: directory.url.appendingPathComponent("missing.xcappdata"))
            Issue.record("Missing source was accepted")
        } catch {}
        #expect(await calls.commands.isEmpty)
        do {
            try await inspector.downloadApplicationData(bundleIdentifier: "dev.example.app", to: directory.url)
            Issue.record("Existing destination was accepted")
        } catch {}
        #expect(await calls.commands.isEmpty)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "preserved")
    }

    @Test(arguments: ["nested", "same", "ancestor"])
    func exportDoesNotModifyItsLiveSourceContainer(destinationKind: String) async throws {
        let directory = try TemporaryTestDirectory()
        let manager = FileManager.default
        let container = directory.url.appendingPathComponent("Container", isDirectory: true)
        let alias = directory.url.appendingPathComponent("ContainerAlias", isDirectory: true)
        try manager.createDirectory(at: container, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: alias, withDestinationURL: container)
        let document = container.appendingPathComponent("document")
        try Data("live data".utf8).write(to: document)
        // A regressed nested export must fail before it can recursively copy its own output.
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path) }
        let destination: URL = switch destinationKind {
        case "nested": alias.appendingPathComponent("Export.xcappdata")
        case "same": container
        default: directory.url
        }
        let calls = InspectorCalls { _ in Self.output(container.path) }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        do {
            try await inspector.downloadApplicationData(bundleIdentifier: "dev.example.app", to: destination, replacingExistingFile: true)
            Issue.record("Export changed a location overlapping its live source")
        } catch let failure as DeviceInspectorFailure {
            if case .applicationDataDownload(let retained) = failure.partialCompletion {
                try? manager.removeItem(at: retained)
                Issue.record("Export created staging before checking source overlap")
            }
            guard case .invalidApplicationData = failure.error as? DeviceInspectorError else {
                Issue.record("Export failed after touching the filesystem rather than rejecting the overlapping location")
                return
            }
        }
        #expect(try String(contentsOf: document, encoding: .utf8) == "live data")
        #expect(try manager.contentsOfDirectory(atPath: container.path) == ["document"])
        #expect(try manager.contentsOfDirectory(atPath: directory.url.path).sorted() == ["Container", "ContainerAlias"])
    }

    @Test func remoteReplacementStopsOnlyTheSelectedAppUsingFileURLExecutables() async throws {
        let directory = try TemporaryTestDirectory()
        let calls = InspectorCalls { command in
            if command.arguments.starts(with: ["device", "info", "apps"]) { return Self.output(Self.apps) }
            if command.arguments.starts(with: ["device", "info", "processes"]) {
                return Self.output(#"{"result":{"runningProcesses":[{"executable":"file:///private/remote/Remote.app/Executable","processIdentifier":123},{"executable":"file:///private/remote/Remote.app-other/Executable","processIdentifier":456}]}}"#)
            }
            return Self.output("")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        try await inspector.replaceApplicationData(bundleIdentifier: "dev.example.app", from: directory.url)
        let commands = await calls.commands
        let stops = commands.filter { $0.arguments.starts(with: ["device", "process", "terminate"]) }
        #expect(stops.count == 1 && stops.first?.arguments.contains("123") == true)
        #expect(stops.first?.arguments.contains("456") == false)
        #expect(commands.last?.arguments.starts(with: ["device", "copy", "to"]) == true)
    }

    @Test func customSetProfileAndIconRequestsAreNotSentToTheDefaultCoreDeviceSet() async throws {
        let calls = InspectorCalls { _ in Self.output("") }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        do { _ = try await inspector.profiles(); Issue.record("Custom set profiles were misrouted") }
        catch let failure as DeviceInspectorFailure { #expect(failure.deviceID == .simulator(udid: "sim-udid", deviceSetPath: "/fixture-device-set")) }
        do { _ = try await inspector.applicationIcon(bundleIdentifier: "dev.example.app"); Issue.record("Custom set icon was misrouted") }
        catch let failure as DeviceInspectorFailure { #expect(failure.error is DeviceInspectorError) }
        #expect(await calls.commands.isEmpty)
    }

    @Test func approvedExportReplacesExistingPackageAfterCompleteCopy() async throws {
        let directory = try TemporaryTestDirectory()
        let source = directory.url.appendingPathComponent("Container")
        let destination = directory.url.appendingPathComponent("App.xcappdata")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("new data".utf8).write(to: source.appendingPathComponent("document"))
        try Data("old export".utf8).write(to: destination.appendingPathComponent("old"))
        let calls = InspectorCalls { _ in Self.output(source.path) }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        try await inspector.downloadApplicationData(bundleIdentifier: "dev.example.app", to: destination, replacingExistingFile: true)
        #expect(try String(contentsOf: destination.appendingPathComponent("AppData/document"), encoding: .utf8) == "new data")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted() == ["App.xcappdata", "Container"])
    }

    @Test func failedApprovedExportPreservesOriginalAndRetainsStagingForRecovery() async throws {
        let directory = try TemporaryTestDirectory()
        let calls = InspectorCalls { command in
            let index = try #require(command.arguments.firstIndex(of: "--destination"))
            let data = URL(fileURLWithPath: command.arguments[index + 1])
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
            try Data("partial".utf8).write(to: data.appendingPathComponent("partial"))
            throw CLIError.io("copy-fixture", "Device disconnected during transfer")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let destination = directory.url.appendingPathComponent("App.xcappdata")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let original = destination.appendingPathComponent("keep")
        try Data("original export".utf8).write(to: original)
        do {
            try await inspector.downloadApplicationData(bundleIdentifier: "dev.example.app", to: destination, replacingExistingFile: true)
            Issue.record("Transfer failure was ignored")
        } catch let failure as DeviceInspectorFailure {
            guard case .applicationDataDownload(let remaining) = failure.partialCompletion else {
                Issue.record("The partial download URL was lost")
                return
            }
            #expect(remaining != destination)
            #expect(try String(contentsOf: remaining.appendingPathComponent("AppData/partial"), encoding: .utf8) == "partial")
            #expect(failure.deviceID == .coreDevice("core-command-id"))
            #expect(failure.source == .coreDevice)
            #expect((failure.error as? CLIError)?.identifier == "copy-fixture")
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original export")
    }

    @Test func deviceGeneratedIconIsReturnedAndVoidMutationsDoNotRequireAResultObject() async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let calls = InspectorCalls { command in
            if let index = command.arguments.firstIndex(of: "--destination") {
                try png.write(to: URL(fileURLWithPath: command.arguments[index + 1]))
            }
            return Self.output("")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        #expect(try await inspector.applicationIcon(bundleIdentifier: "dev.example.app") == png)
        try await inspector.installApplication(at: URL(fileURLWithPath: "/fixture/App.app"))
        try await inspector.launchApplication(bundleIdentifier: "dev.example.app")
        try await inspector.uninstallApplication(bundleIdentifier: "dev.example.app")
        #expect(await calls.commands.count == 4)
    }

    @Test func packageInstallsItsExtractedMainApplicationOnTheSelectedDestination() async throws {
        let directory = try TemporaryTestDirectory()
        let package = try Self.applicationPackage(in: directory, bundles: ["Payload/App.app", "Payload/App.app/Watch/Watch.app"])
        let calls = InspectorCalls { command in
            let application = try #require(command.arguments.first { $0.hasSuffix(".app") })
            #expect(try String(contentsOfFile: application + "/Info.plist", encoding: .utf8) == "Payload/App.app")
            return Self.output("")
        }
        let transport = DeviceInspectorTransport(run: { try await calls.run($0) })
        try await Self.simulator(transport: transport).installApplication(at: package)
        try await Self.remote(transport: transport).installApplication(at: package)
        let commands = await calls.commands
        let simulator = try #require(commands.first), remote = try #require(commands.last)
        let staged = try #require(simulator.arguments.last)
        #expect(simulator.source == .simulator(xcodeURL: Self.xcode, deviceSetPath: "/fixture-device-set"))
        #expect(simulator.arguments == ["install", "sim-udid", staged] && staged.hasSuffix("/Payload/App.app"))
        #expect(remote.source == .coreDevice && remote.arguments.starts(with: ["device", "install", "app"]) && remote.arguments.contains("core-command-id"))
        #expect(commands.count == 2)
        for command in commands { try Self.expectStagingRemoved(for: command) }
        #expect(FileManager.default.fileExists(atPath: package.path))
    }

    @Test func packageWithoutOneApplicationIsNotSentToTheInstaller() async throws {
        let directory = try TemporaryTestDirectory()
        let corrupt = directory.url.appendingPathComponent("Corrupt.ipa")
        try Data("not an archive".utf8).write(to: corrupt)
        let unpackaged = try Self.applicationPackage(in: directory, bundles: ["App.app"])
        let calls = InspectorCalls { _ in Self.output("") }
        let inspector = Self.simulator(transport: .init(run: { try await calls.run($0) }))
        do { try await inspector.installApplication(at: corrupt); Issue.record("A corrupt package was installed") }
        catch let failure as DeviceInspectorFailure {
            guard case .commandFailed(_, _, let stderr) = failure.error as? DeviceInspectorError else { Issue.record("Lost the extraction diagnostics"); return }
            #expect(!stderr.isEmpty && failure.source == .file(corrupt))
        }
        do { try await inspector.installApplication(at: unpackaged); Issue.record("A package without a payload application was installed") }
        catch let failure as DeviceInspectorFailure { #expect((failure.error as? CocoaError)?.code == .fileReadCorruptFile) }
        #expect(await calls.commands.isEmpty)
    }

    @Test func packageInstallerOutcomesKeepTheirErrorsAndRemoveStaging() async throws {
        let directory = try TemporaryTestDirectory()
        let package = try Self.applicationPackage(in: directory, bundles: ["Payload/App.app"])
        let calls = InspectorCalls { command in
            if command.source == .coreDevice { throw CancellationError() }
            return CommandOutput(terminationStatus: 1, stdout: Data(), stderr: Data("Incompatible platform".utf8))
        }
        let transport = DeviceInspectorTransport(run: { try await calls.run($0) })
        do { try await Self.simulator(transport: transport).installApplication(at: package); Issue.record("Installer failure was ignored") }
        catch let failure as DeviceInspectorFailure {
            guard case .commandFailed(1, _, "Incompatible platform") = failure.error as? DeviceInspectorError else { Issue.record("Lost the installer diagnostics"); return }
            #expect(failure.source == .simulator(xcodeURL: Self.xcode, deviceSetPath: "/fixture-device-set"))
        }
        do { try await Self.remote(transport: transport).installApplication(at: package); Issue.record("Cancellation was ignored") }
        catch let failure as DeviceInspectorFailure { #expect(failure.error is CancellationError) }
        for command in await calls.commands { try Self.expectStagingRemoved(for: command) }

        // The installed application must remain distinguishable from a failed installation.
        let locking = InspectorCalls { command in
            let payload = URL(fileURLWithPath: try #require(command.arguments.last)).deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: payload.path)
            return Self.output("")
        }
        do {
            try await Self.simulator(transport: .init(run: { try await locking.run($0) })).installApplication(at: package)
            Issue.record("Cleanup failure was ignored")
        } catch let failure as DeviceInspectorFailure {
            guard case .cleanupFailed(let staging, let operationError, _) = failure.error as? DeviceInspectorError else { Issue.record("Lost the cleanup failure"); return }
            #expect(operationError == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.appendingPathComponent("Payload").path)
            try FileManager.default.removeItem(at: staging)
        }
    }

    /// Archives each bundle, with an Info.plist naming its path, as an application package.
    private static func applicationPackage(in directory: TemporaryTestDirectory, bundles: [String]) throws -> URL {
        let contents = directory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for bundle in bundles {
            let url = contents.appendingPathComponent(bundle, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(bundle.utf8).write(to: url.appendingPathComponent("Info.plist"))
        }
        let package = directory.url.appendingPathComponent("\(UUID().uuidString).ipa")
        let output = try SystemCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", contents.path, package.path])
        try #require(output.terminationStatus == 0, "\(output.stderrText)")
        return package
    }
    private static func expectStagingRemoved(for command: DeviceInspectorCommand) throws {
        let application = URL(fileURLWithPath: try #require(command.arguments.first { $0.hasSuffix(".app") }))
        #expect(!FileManager.default.fileExists(atPath: application.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    private static let xcode = URL(fileURLWithPath: "/Applications/FixtureXcode.app")
    private static func simulator(deviceSetPath: String? = "/fixture-device-set", transport: DeviceInspectorTransport) -> DeviceInspector {
        let item = SimulatorHostDevice(identifier: "sim-udid", name: "Simulator", descriptiveName: "Simulator", runtimeIdentifier: "runtime", runtimeName: "iOS 27.2", productFamily: "iPhone", state: "Booted", ownerXcodeURL: xcode, deviceSetPath: deviceSetPath)
        return DeviceInspector(device: .simulator(item), simulatorXcodeURL: xcode, transport: transport)
    }
    private static func remote(transport: DeviceInspectorTransport) throws -> DeviceInspector {
        let data = Data(#"""
        {"result":{"devices":[{"identifier":"core-command-id","properties":{"hardware":{"reality":"physical","udid":"hardware-udid"},"state":{"name":"Remote Phone"},"connection":{"state":"connected"}}}]}}
        """#.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        return DeviceInspector(device: .remote(device), simulatorXcodeURL: nil, transport: transport)
    }
    private static func output(_ string: String) -> CommandOutput { CommandOutput(terminationStatus: 0, stdout: Data(string.utf8), stderr: Data()) }
    private static let apps = #"""
    {"result":{"apps":[{"bundleIdentifier":"dev.example.other","name":"AAA Other App"},{"bundleIdentifier":"dev.example.app","name":"Remote App","version":"2.0","bundleVersion":"42","url":"file:///private/remote/Remote.app/","dataContainerPath":"/private/remote/Data","containerAccessible":true,"builtByDeveloper":true,"removable":true}]}}
    """#
    private static let profiles = #"""
    {"result":{"configurationProfiles":[{"identifier":"record-id","payloadIdentifier":"dev.example.configuration","uuid":"profile-uuid","name":"Config","payloadTypes":["com.apple.wifi.managed"]}],"provisioningProfiles":[{"identifier":"provisioning-uuid","name":"Provision","entitlements":["get-task-allow"]}],"partialConfigurationProfiles":[],"partialProvisioningProfiles":[{"identifier":"partial-profile"}]}}
    """#
}

private actor InspectorCalls {
    private(set) var commands: [DeviceInspectorCommand] = []
    let respond: @Sendable (DeviceInspectorCommand) throws -> CommandOutput
    init(respond: @escaping @Sendable (DeviceInspectorCommand) throws -> CommandOutput) { self.respond = respond }
    func run(_ command: DeviceInspectorCommand) throws -> CommandOutput {
        commands.append(command)
        return try respond(command)
    }
}

import Foundation
import Testing
@testable import XcodeSimulatorHost

@Suite struct DeviceReportTests {
    @Test func metadataPreservesReportedTypeAndKeepsValidEntriesOnPartialDecodeFailure() async throws {
        let inspector = try Self.remote(transport: .init(run: { _ in Self.output(Self.files) }))
        let snapshot = try await inspector.reports()
        #expect(snapshot.deviceID == .coreDevice("report-device"))
        #expect(snapshot.reports.count == 3 && snapshot.issues.count == 1)
        let report = try #require(snapshot.reports.first { $0.relativePath == "Nested/Report.ips" })
        #expect(report.size == 128 && report.modificationDate == Date(timeIntervalSince1970: 0))
        #expect(report.type.fileExtension == "ips")
        #expect(report.type.recordedLogType == "fixture-log-type" && report.type.bugType == "fixture-bug-type")
        #expect(report.resources.isReadable == true && !report.resources.isDirectory)
        #expect(report.metadata["extendedAttributes"]?["unknownAttribute"]?.string == "retained")
        #expect(snapshot.reports.first { $0.relativePath == "Other.ips" }?.type.recordedLogType == nil)
        #expect(snapshot.reports.first { $0.relativePath == "Folder" }?.resources.isDirectory == true)
        let issue = try #require(snapshot.issues.first)
        #expect(issue.relativePath == "../outside.ips" && issue.error.deviceID == inspector.device.id)
        #expect(try await inspector.report(relativePath: report.relativePath) == report)
        #expect(inspector.supportsReportListing && inspector.supportsReportDownload)
    }

    @Test func simulatorReportsAreUnsupportedWithoutRunningACommand() async throws {
        let calls = ReportCalls { _ in Self.output(Self.files) }
        let simulator = SimulatorHostDevice(identifier: "simulator", name: "Simulator", descriptiveName: "Simulator", runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted")
        let inspector = DeviceInspector(device: .simulator(simulator), simulatorXcodeURL: URL(fileURLWithPath: "/fixture/Xcode.app"), transport: .init(run: { try await calls.run($0) }))
        #expect(!inspector.supportsReportListing && !inspector.supportsReportDownload)
        do { _ = try await inspector.reports(); Issue.record("Simulator reports returned an empty success") }
        catch let error as DeviceInspectorFailure {
            guard case .unsupported = error.error as? DeviceInspectorError else { Issue.record("Unsupported reason was lost"); return }
        }
        #expect(await calls.commands.isEmpty)
    }

    @Test func explicitReplacementPublishesOnlyAfterDownloadAndUsesTheRequestedDestination() async throws {
        let directory = try TemporaryTestDirectory()
        let directoryURL = directory.url
        let destination = directoryURL.appendingPathComponent("Chosen Name.txt")
        try Data("original".utf8).write(to: destination)
        let calls = ReportCalls { command in
            guard command.arguments.starts(with: ["device", "copy", "from"]) else { return Self.output(Self.files) }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
            let staged = try Self.destination(command)
            #expect(staged != destination)
            #expect(staged.deletingLastPathComponent().deletingLastPathComponent().path == directoryURL.path)
            try Data("complete report".utf8).write(to: staged)
            return Self.output("")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let report = try await inspector.report(relativePath: "Nested/Report.ips")
        do { _ = try await inspector.downloadReport(report, to: destination); Issue.record("Existing destination replaced without consent") }
        catch {}
        #expect(await calls.commands.filter { $0.arguments.starts(with: ["device", "copy", "from"]) }.isEmpty)
        let saved = try await inspector.downloadReport(report, to: destination, replacingExistingFile: true)
        #expect(saved == destination)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "complete report")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["Chosen Name.txt"])
        let copy = try #require(await calls.commands.last)
        #expect(copy.source == .coreDevice && copy.arguments.contains("report-device"))
        #expect(copy.arguments.contains("systemCrashLogs") && copy.arguments.contains("Nested/Report.ips"))
    }

    @Test func failedTransferPreservesExistingFileAndReportsOwnedPartialData() async throws {
        let directory = try TemporaryTestDirectory()
        let destination = directory.url.appendingPathComponent("Existing.ips")
        try Data("original".utf8).write(to: destination)
        let calls = ReportCalls { command in
            guard command.arguments.starts(with: ["device", "copy", "from"]) else { return Self.output(Self.files) }
            try Data("partial transfer".utf8).write(to: Self.destination(command))
            throw CLIError.io("report-transfer-fixture", "Disconnected")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let report = try await inspector.report(relativePath: "Nested/Report.ips")
        do { _ = try await inspector.downloadReport(report, to: destination, replacingExistingFile: true); Issue.record("Transfer failure was ignored") }
        catch let error as DeviceInspectorFailure {
            #expect(error.deviceID == inspector.device.id && error.source == .coreDevice)
            #expect((error.error as? CLIError)?.identifier == "report-transfer-fixture")
            guard case .reportDownload(let target, let remaining, let updated) = error.partialCompletion else { Issue.record("Partial path was lost"); return }
            #expect(target == destination && !updated)
            #expect(try String(contentsOf: remaining, encoding: .utf8) == "partial transfer")
            #expect(remaining.deletingLastPathComponent().deletingLastPathComponent().path == directory.url.path)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }

    @Test func cancelledTransferDoesNotPublishOverTheChosenFile() async throws {
        let directory = try TemporaryTestDirectory()
        let destination = directory.url.appendingPathComponent("Existing.ips")
        try Data("original".utf8).write(to: destination)
        let calls = ReportCalls { command in
            guard command.arguments.starts(with: ["device", "copy", "from"]) else { return Self.output(Self.files) }
            try Data("complete transfer".utf8).write(to: Self.destination(command))
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.output("")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let report = try await inspector.report(relativePath: "Nested/Report.ips")
        let operation = Task { try await inspector.downloadReport(report, to: destination, replacingExistingFile: true) }
        do { _ = try await operation.value; Issue.record("A cancelled transfer replaced the chosen file") }
        catch let error as DeviceInspectorFailure {
            #expect(error.error is CancellationError)
            guard case .reportDownload(let target, _, let updated) = error.partialCompletion else { Issue.record("Staging state was lost"); return }
            #expect(target == destination && !updated)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }

    @Test func previewsKeepSameNamedReportsSeparateAndCannotTransferAnotherDevicesReport() async throws {
        let directory = try TemporaryTestDirectory()
        let calls = ReportCalls { command in
            guard command.arguments.starts(with: ["device", "copy", "from"]) else { return Self.output(Self.files) }
            let deviceIndex = try #require(command.arguments.firstIndex(of: "--device"))
            try Data(command.arguments[deviceIndex + 1].utf8).write(to: Self.destination(command))
            return Self.output("")
        }
        let transport = DeviceInspectorTransport(run: { try await calls.run($0) })
        let first = try Self.remote(identifier: "device-a", transport: transport)
        let second = try Self.remote(identifier: "device-b", reality: "virtual", transport: transport)
        let reportA = try await first.report(relativePath: "Nested/Report.ips")
        let reportB = try await second.report(relativePath: "Nested/Report.ips")
        do { _ = try await second.downloadReport(reportA, to: directory.url.appendingPathComponent("wrong.ips")); Issue.record("Report was routed to another device") }
        catch {}
        #expect(await calls.commands.filter { $0.arguments.starts(with: ["device", "copy", "from"]) }.isEmpty)
        let previewA = try await first.previewReport(reportA, in: directory.url)
        let previewB = try await second.previewReport(reportB, in: directory.url)
        #expect(previewA.url.lastPathComponent == "Report.ips" && previewB.url.lastPathComponent == "Report.ips")
        #expect(previewA.url != previewB.url)
        #expect(try String(contentsOf: previewA.url, encoding: .utf8) == "device-a")
        #expect(try String(contentsOf: previewB.url, encoding: .utf8) == "device-b")
        try await previewA.removeCachedCopy()
        try await previewA.removeCachedCopy()
        #expect(FileManager.default.fileExists(atPath: previewB.url.path))
        try await previewB.removeCachedCopy()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func previewFailureCleansItsPrivateDirectoryAndRetainsTheTransferError() async throws {
        let directory = try TemporaryTestDirectory()
        let calls = ReportCalls { command in
            guard command.arguments.starts(with: ["device", "copy", "from"]) else { return Self.output(Self.files) }
            try Data("partial".utf8).write(to: Self.destination(command))
            throw CLIError.io("preview-transfer-fixture", "Disconnected")
        }
        let inspector = try Self.remote(transport: .init(run: { try await calls.run($0) }))
        let report = try await inspector.report(relativePath: "Nested/Report.ips")
        do { _ = try await inspector.previewReport(report, in: directory.url); Issue.record("Preview failure was ignored") }
        catch let error as DeviceInspectorFailure {
            #expect((error.error as? CLIError)?.identifier == "preview-transfer-fixture")
            #expect(error.partialCompletion == nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    private static func remote(identifier: String = "report-device", reality: String = "physical", transport: DeviceInspectorTransport) throws -> DeviceInspector {
        let data = Data("""
        {"result":{"devices":[{"identifier":"\(identifier)","properties":{"hardware":{"reality":"\(reality)","udid":"hardware-id"},"state":{"name":"Fixture"}},"capabilities":[{"featureIdentifier":"com.apple.coredevice.feature.listFiles"},{"featureIdentifier":"com.apple.coredevice.feature.transferFiles"}]}]}}
        """.utf8)
        let device = try #require(CoreDeviceInventoryDecoder.decode(data).first)
        return DeviceInspector(device: .remote(device), simulatorXcodeURL: nil, transport: transport)
    }
    private static func output(_ text: String) -> CommandOutput { CommandOutput(terminationStatus: 0, stdout: Data(text.utf8), stderr: Data()) }
    private static func destination(_ command: DeviceInspectorCommand) throws -> URL {
        let index = try #require(command.arguments.firstIndex(of: "--destination"))
        return URL(fileURLWithPath: command.arguments[index + 1])
    }
    private static let files = #"""
    {"result":{"files":[
      {"name":"misleading/../../Name","relativePath":"Nested/Report.ips","metadata":{"size":128,"lastModDate":"1970-01-01T00:00:00.000Z","extendedAttributes":{"LogType":"fixture-log-type","bug_type":"fixture-bug-type","unknownAttribute":"retained"}},"resources":{"isDirectory":false,"isReadable":true,"isHidden":false,"isSymbolicLink":false,"isWritable":false}},
      {"name":"Other.ips","relativePath":"Other.ips","metadata":{},"resources":{"isDirectory":false}},
      {"name":"Folder","relativePath":"Folder","metadata":{},"resources":{"isDirectory":true}},
      {"name":"bad","relativePath":"../outside.ips","metadata":{},"resources":{"isDirectory":false}}
    ]}}
    """#
}

private actor ReportCalls {
    private(set) var commands: [DeviceInspectorCommand] = []
    let respond: @Sendable (DeviceInspectorCommand) throws -> CommandOutput
    init(respond: @escaping @Sendable (DeviceInspectorCommand) throws -> CommandOutput) { self.respond = respond }
    func run(_ command: DeviceInspectorCommand) throws -> CommandOutput {
        commands.append(command)
        return try respond(command)
    }
}

import Foundation

public struct DeviceReport: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let deviceID: DeviceInventoryID
        public let relativePath: String
    }
    /// Values reported by the source, without inferring a crash or hang from an .ips suffix.
    public struct FileType: Equatable, Sendable {
        public let fileExtension: String
        public let recordedLogType: String?
        public let bugType: String?
    }
    public struct Resources: Equatable, Sendable {
        public let isDirectory: Bool
        public let isHidden: Bool?
        public let isReadable: Bool?
        public let isSymbolicLink: Bool?
        public let isWritable: Bool?
    }
    public var id: ID { ID(deviceID: deviceID, relativePath: relativePath) }
    public let deviceID: DeviceInventoryID
    public let relativePath: String
    public let name: String
    public let size: Int64?
    public let modificationDate: Date?
    public let type: FileType
    public let resources: Resources
    public let metadata: [String: DeviceInspectorValue]
}

public struct DeviceReportIssue: Sendable {
    public let relativePath: String?
    public let error: DeviceInspectorFailure
}

public struct DeviceReportsSnapshot: Sendable {
    public let deviceID: DeviceInventoryID
    public let reports: [DeviceReport]
    /// Malformed entries do not remove reports successfully decoded from the same response.
    public let issues: [DeviceReportIssue]
}

/// A downloaded preview in a directory created exclusively for this handle.
/// The caller owns its lifetime and removes it when closing the preview or changing devices.
public struct DeviceReportPreview: Sendable {
    public let report: DeviceReport
    public let url: URL
    private let directory: URL

    fileprivate init(report: DeviceReport, url: URL, directory: URL) {
        self.report = report
        self.url = url
        self.directory = directory
    }

    /// Removes only the directory created for this preview. Repeated removal is harmless.
    @concurrent public func removeCachedCopy() async throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        catch {
            throw DeviceInspectorFailure(deviceID: report.deviceID, operation: "Remove Report Preview", source: .file(directory),
                error: error, partialCompletion: nil)
        }
    }
}

extension DeviceInspector {
    /// Advertised support in this inventory snapshot; a subsequent request can reconnect
    /// a device and discover capabilities that were absent from the snapshot.
    public var supportsReportListing: Bool {
        if case .remote = device { device.capabilities.contains("com.apple.coredevice.feature.listFiles") } else { false }
    }
    public var supportsReportDownload: Bool {
        if case .remote = device { device.capabilities.contains("com.apple.coredevice.feature.transferFiles") } else { false }
    }

    @concurrent public func reports() async throws -> DeviceReportsSnapshot {
        try requireReportDestination()
        let result = try await coreDeviceResult(["device", "info", "files", "--domain-type", "systemCrashLogs", "--recurse"], operation: "Read Reports")
        guard let files = result["files"]?.array else {
            throw failure(DeviceInspectorError.invalidResponse("devicectl omitted its report file list."), operation: "Read Reports", source: .coreDevice)
        }
        var reports: [DeviceReport] = []
        var issues: [DeviceReportIssue] = []
        for file in files {
            do { reports.append(try decodeReport(file)) }
            catch {
                issues.append(DeviceReportIssue(relativePath: file["relativePath"]?.string,
                    error: failure(error, operation: "Read Report Metadata", source: .coreDevice)))
            }
        }
        reports.sort {
            let comparison = $0.relativePath.localizedStandardCompare($1.relativePath)
            return comparison == .orderedAscending
        }
        return DeviceReportsSnapshot(deviceID: device.id, reports: reports, issues: issues)
    }

    /// Refreshes metadata by the report's domain-relative path. It does not reuse another
    /// device's cached report, even when its filename is identical.
    @concurrent public func report(relativePath: String) async throws -> DeviceReport {
        try requireReportDestination()
        try validateReportPath(relativePath)
        let snapshot = try await reports()
        if let report = snapshot.reports.first(where: { $0.relativePath == relativePath }) { return report }
        if let issue = snapshot.issues.first(where: { $0.relativePath == relativePath }) { throw issue.error }
        throw failure(DeviceInspectorError.reportNotFound(relativePath), operation: "Read Report Metadata", source: .coreDevice)
    }

    /// Downloads to a private staging directory beside the chosen destination, then
    /// publishes the complete file. Explicit replacement preserves the existing file
    /// during transfer. Failures retain the staging path in partialCompletion.
    @concurrent public func downloadReport(_ report: DeviceReport, to destination: URL,
                                          replacingExistingFile: Bool = false) async throws -> URL {
        try validateReport(report)
        let manager = FileManager.default
        var stagingDirectory: URL?
        var stagedReport: URL?
        var destinationUpdated = false
        do {
            guard destination.isFileURL else { throw DeviceInspectorError.invalidResponse("The report destination must be a local file URL.") }
            guard replacingExistingFile || !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
            let directory = destination.deletingLastPathComponent().appendingPathComponent(".NeoSimulatorReport-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            stagingDirectory = directory
            let staged = directory.appendingPathComponent((report.relativePath as NSString).lastPathComponent, isDirectory: report.resources.isDirectory)
            stagedReport = staged
            _ = try await coreDevice(["device", "copy", "from", "--domain-type", "systemCrashLogs", "--source", report.relativePath,
                "--destination", staged.path], operation: "Download Report")
            try Task.checkCancellation()
            if replacingExistingFile && manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staged)
            } else { try manager.moveItem(at: staged, to: destination) }
            destinationUpdated = true
            try manager.removeItem(at: directory)
            return destination
        } catch {
            let remaining: URL?
            if let stagedReport, manager.fileExists(atPath: stagedReport.path) { remaining = stagedReport }
            else if let stagingDirectory, manager.fileExists(atPath: stagingDirectory.path) { remaining = stagingDirectory }
            else { remaining = nil }
            throw failure(error, operation: "Download Report", source: .file(destination),
                partialCompletion: remaining.map { .reportDownload(destination: destination, remainingURL: $0, destinationUpdated: destinationUpdated) })
        }
    }

    /// Downloads a preview into an owned UUID directory. Only the server path's basename
    /// becomes a cache filename; nested paths and names cannot escape the cache directory.
    @concurrent public func previewReport(_ report: DeviceReport, in cacheDirectory: URL) async throws -> DeviceReportPreview {
        try validateReport(report)
        let manager = FileManager.default
        let directory = cacheDirectory.appendingPathComponent("NeoSimulatorReport-\(UUID().uuidString)", isDirectory: true)
        var createdDirectory = false
        do {
            guard cacheDirectory.isFileURL else { throw DeviceInspectorError.invalidResponse("The report cache must be a local directory URL.") }
            try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            createdDirectory = true
            let destination = directory.appendingPathComponent((report.relativePath as NSString).lastPathComponent, isDirectory: report.resources.isDirectory)
            let local = try await downloadReport(report, to: destination)
            return DeviceReportPreview(report: report, url: local, directory: directory)
        } catch {
            if createdDirectory {
                do { try manager.removeItem(at: directory) }
                catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile {}
                catch let cleanup {
                    throw failure(DeviceInspectorError.cleanupFailed(directory: directory, operationError: error, cleanupError: cleanup),
                        operation: "Preview Report", source: .file(directory),
                        partialCompletion: .reportDownload(destination: directory, remainingURL: directory, destinationUpdated: false))
                }
            }
            let original = failure(error, operation: "Preview Report")
            throw DeviceInspectorFailure(deviceID: original.deviceID, operation: "Preview Report", source: original.source,
                error: original.error, partialCompletion: nil)
        }
    }

    private func requireReportDestination() throws {
        guard case .remote = device else {
            throw failure(DeviceInspectorError.unsupported("Crash, log, spin, and diagnostic reports are unavailable for simulators."), operation: "Read Reports")
        }
    }

    private func validateReport(_ report: DeviceReport) throws {
        try requireReportDestination()
        guard report.deviceID == device.id else {
            throw failure(DeviceInspectorError.invalidResponse("The report belongs to a different device."), operation: "Download Report", source: .coreDevice)
        }
        try validateReportPath(report.relativePath)
    }

    private func validateReportPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.contains("\0"), !components.isEmpty,
              !components.contains(".."), components.last != "." else {
            throw failure(DeviceInspectorError.invalidResponse("A report path must stay within the report domain."), operation: "Read Report Metadata", source: .coreDevice)
        }
    }

    private func decodeReport(_ value: DeviceInspectorValue) throws -> DeviceReport {
        guard let path = value["relativePath"]?.string else { throw DeviceInspectorError.invalidResponse("A report entry omitted its relative path.") }
        try validateReportPath(path)
        guard let directory = value["resources"]?["isDirectory"]?.boolean else {
            throw DeviceInspectorError.invalidResponse("A report entry omitted its file resources.")
        }
        let metadata = value["metadata"]?.object ?? [:]
        let attributes = metadata["extendedAttributes"]?.object ?? [:]
        let date = metadata["lastModDate"]?.string.flatMap { value in
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value))
        }
        let size: Int64? = if case .integer(let value) = metadata["size"] { value } else { nil }
        return DeviceReport(deviceID: device.id, relativePath: path, name: value["name"]?.string ?? (path as NSString).lastPathComponent,
            size: size, modificationDate: date,
            type: .init(fileExtension: (path as NSString).pathExtension, recordedLogType: attributes["LogType"]?.string, bugType: attributes["bug_type"]?.string),
            resources: .init(isDirectory: directory, isHidden: value["resources"]?["isHidden"]?.boolean,
                isReadable: value["resources"]?["isReadable"]?.boolean, isSymbolicLink: value["resources"]?["isSymbolicLink"]?.boolean,
                isWritable: value["resources"]?["isWritable"]?.boolean), metadata: metadata)
    }
}

import ABIBridge
import Darwin
import Foundation
import NeoSimulatorNative
import Synchronization

package struct XcodeInstallationInspector {
    private struct FileRevision: Equatable, Sendable {
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let size: off_t
        let fileNumber: ino_t
        let systemNumber: dev_t
    }

    private struct BundleMetadata: Sendable {
        let bundleIdentifier: String?
        let version: String?
        let build: String?
    }

    private struct CachedMetadata: Sendable {
        let revision: FileRevision
        let metadata: BundleMetadata
    }

    private static let metadataCache = Mutex<[URL: CachedMetadata]>([:])
    private let environment: [String: String]
    private let readSelection: @Sendable () async throws -> URL

    package init(reads: CommandReads? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                 readSelection: (@Sendable () async throws -> URL)? = nil) {
        self.environment = environment
        let selection: @Sendable () async throws -> URL = readSelection ?? { try await NativeXcodeSelection.read() }
        self.readSelection = {
            if let reads { return try await reads.read(selection) }
            return try await selection()
        }
    }

    package nonisolated(nonsending) func selectedXcode() async throws -> XcodeInstallation {
        let developerDirectory = try await selectedDeveloperDirectory()
        let xcodeURL = try xcodeApplicationURL(forDeveloperDirectory: developerDirectory)
        return try xcode(at: xcodeURL)
    }

    /// Nil when no usable Xcode is selected. Cancellation still throws, because it says nothing about the selection.
    package nonisolated(nonsending) func selectedXcodeIfUsable() async throws -> XcodeInstallation? {
        do { return try await selectedXcode() }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    package nonisolated(nonsending) func xcodeForUIFrameworks(override: URL?) async throws -> XcodeInstallation {
        if let override { return try xcode(at: override) }
        return try await selectedXcode()
    }

    package func xcode(at url: URL) throws -> XcodeInstallation {
        let xcode = try inspectXcode(at: url.resolvingSymlinksInPath().standardizedFileURL)

        guard xcode.version.major >= ToolConstants.minimumSupportedXcodeMajorVersion else {
            throw DeviceIOError.unavailable(
                "unsupported-xcode",
                "Xcode \(xcode.version) is selected; Xcode 27 or later is required"
            )
        }
        return xcode
    }

    private nonisolated(nonsending) func selectedDeveloperDirectory() async throws -> URL {
        if let path = environment["DEVELOPER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        return try await readSelection().standardizedFileURL
    }

    private func xcodeApplicationURL(forDeveloperDirectory url: URL) throws -> URL {
        guard url.lastPathComponent == "Developer" else {
            throw DeviceIOError.unavailable(
                "developer-directory",
                "DEVELOPER_DIR must end in Contents/Developer: \(url.path)"
            )
        }
        let contentsURL = url.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else {
            throw DeviceIOError.unavailable(
                "developer-directory",
                "DEVELOPER_DIR must end in Contents/Developer: \(url.path)"
            )
        }
        return contentsURL.deletingLastPathComponent().standardizedFileURL
    }

    private func inspectXcode(at applicationURL: URL) throws -> XcodeInstallation {
        let info = try bundleMetadata(
            at: applicationURL.appendingPathComponent("Contents/Info.plist")
        )
        guard info.bundleIdentifier == ToolConstants.xcodeBundleIdentifier,
              let versionString = info.version
        else {
            throw DeviceIOError.unavailable(
                "xcode-bundle",
                "\(applicationURL.path) is not a valid Xcode application"
            )
        }
        let version = try ToolVersion(versionString)

        let versionInfo = try bundleMetadata(
            at: applicationURL.appendingPathComponent("Contents/version.plist")
        )
        guard let buildVersion = versionInfo.build else {
            throw DeviceIOError.unavailable(
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

    private func bundleMetadata(at url: URL) throws -> BundleMetadata {
        var attributes = stat()
        guard stat(url.path, &attributes) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            throw DeviceIOError.unavailable("bundle-property-list", "could not read \(url.path): \(error.localizedDescription)")
        }
        let revision = FileRevision(modifiedSeconds: attributes.st_mtimespec.tv_sec,
                                    modifiedNanoseconds: attributes.st_mtimespec.tv_nsec,
                                    size: attributes.st_size,
                                    fileNumber: attributes.st_ino,
                                    systemNumber: attributes.st_dev)
        if let cached = Self.metadataCache.withLock({ $0[url] }), cached.revision == revision {
            return cached.metadata
        }
        let info = try propertyList(at: url)
        let metadata = BundleMetadata(bundleIdentifier: info["CFBundleIdentifier"] as? String,
                                      version: info["CFBundleShortVersionString"] as? String,
                                      build: info["ProductBuildVersion"] as? String)
        Self.metadataCache.withLock { $0[url] = CachedMetadata(revision: revision, metadata: metadata) }
        return metadata
    }

    package func propertyList(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DeviceIOError.unavailable(
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
                throw DeviceIOError.configuration(
                    "bundle-property-list",
                    "\(url.path) is not a dictionary"
                )
            }
            return dictionary
        } catch let error as DeviceIOError {
            throw error
        } catch {
            throw DeviceIOError.configuration(
                "bundle-property-list",
                "could not decode \(url.path): \(error.localizedDescription)"
            )
        }
    }
}

private enum NativeXcodeSelection {
    private static let binding = Task {
        try await NativeFrameworks.load("/usr/lib/libxcselect.dylib")
        return try await ABIRuntime.shared.resolve(.c(.function("xcselect_get_developer_dir_path",
            as: ((UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Bool>,
                  UnsafeMutablePointer<Bool>) -> Bool).self)),
            in: .installName("/usr/lib/libxcselect.dylib"), loading: .loadedOnly)
    }

    @concurrent
    static func read() async throws -> URL {
        try Task.checkCancellation()
        let read = try await binding.value
        try Task.checkCancellation()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var sources = [Bool](repeating: false, count: 3)
        let found = try buffer.withUnsafeMutableBufferPointer { path in
            try sources.withUnsafeMutableBufferPointer { sources in
                let source = sources.baseAddress!
                return try unsafe read.unsafeInvoke(path.baseAddress!, path.count, source, source + 1, source + 2)
            }
        }
        guard found else { throw DeviceIOError.unavailable("selected-xcode", "No developer directory is selected.") }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

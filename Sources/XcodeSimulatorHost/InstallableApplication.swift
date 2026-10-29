import Foundation

/// Calls `body` with an application bundle that the device's installer accepts.
///
/// A `.app` bundle is passed unchanged. The main application of an `.ipa` package,
/// its single `Payload/*.app` directory, is extracted into a new temporary directory
/// that remains until `body` returns. The installer decides whether the application's
/// platform and signature suit the device.
///
/// - Throws: The extraction or `body` error. When the temporary directory cannot be
///   removed, ``DeviceInspectorError/cleanupFailed(directory:operationError:cleanupError:)``
///   carries that error, and a `nil` operation error means `body` succeeded.
nonisolated(nonsending)
public func withInstallableApplication(at url: URL, _ body: (URL) async throws -> Void) async throws {
    guard url.pathExtension.lowercased() == "ipa" else { return try await body(url) }
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("NeoSimulator-application-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let result: Result<Void, any Error>
    do {
        let output = try await SystemCommandRunner.runCancellable(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                                                  arguments: ["-x", "-k", url.path, directory.path])
        guard output.terminationStatus == 0 else {
            throw DeviceInspectorError.commandFailed(status: output.terminationStatus, stdout: output.stdoutText, stderr: output.stderrText)
        }
        result = .success(try await body(try mainApplication(extractedTo: directory, from: url)))
    } catch { result = .failure(error) }
    do { try manager.removeItem(at: directory) }
    catch {
        let operationError: (any Error)?
        if case .failure(let failure) = result { operationError = failure } else { operationError = nil }
        throw DeviceInspectorError.cleanupFailed(directory: directory, operationError: operationError, cleanupError: error)
    }
    try result.get()
}

private func mainApplication(extractedTo directory: URL, from package: URL) throws -> URL {
    let contents: [URL]
    do {
        contents = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Payload", isDirectory: true),
                                                               includingPropertiesForKeys: [.isDirectoryKey])
    } catch CocoaError.fileReadNoSuchFile { contents = [] }
    // A symbolic link is not a directory here, so it cannot select a bundle outside the package.
    let applications = try contents.filter {
        try $0.pathExtension.lowercased() == "app" && $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }
    guard applications.count == 1 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: package]) }
    return applications[0]
}

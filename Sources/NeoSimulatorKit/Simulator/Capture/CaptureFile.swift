import Darwin
import Foundation
import NeoSimulatorDeviceIO
import Synchronization

/// Where a capture's blocking file and process work runs, away from whoever asked for it. Holding a lane shows what
/// that caller can still do while a disk is slow.
package protocol CaptureLane: Sendable {
    func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value
}

package struct BlockingIOLane: CaptureLane {
    package init() {}

    package func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await performBlockingIO(work)
    }
}

/// A capture that reached its destination, whose original could not then be removed.
package struct CaptureLeftBehind: LocalizedError {
    package let destination: URL
    package let original: URL
    package let cleanup: any Error

    package var errorDescription: String? {
        "Saved \(destination.lastPathComponent) in \(destination.deletingLastPathComponent().path), but its temporary file remains at \(original.path): \(cleanup.localizedDescription)"
    }
}

package enum CaptureFile {
    /// Destinations and private files touched by a transfer, until its owner acknowledges completion.
    package final class Locations: Sendable {
        private let files = Mutex<Set<URL>>([])
        package var locations: [URL] { files.withLock { Array($0) } }
        fileprivate func insert(_ file: URL) { files.withLock { _ = $0.insert(file) } }
        fileprivate func remove(_ file: URL) { files.withLock { _ = $0.remove(file) } }
        package func clear() { files.withLock { $0.removeAll() } }
    }
    /// Screenshot filename in local time.
    package static func screenshotName(device: String, date: Date) -> String {
        name("Simulator Screenshot", device: device, date: date, extension: "png")
    }

    /// Recording filename in local time.
    package static func recordingName(device: String, date: Date) -> String {
        name("Simulator Screen Recording", device: device, date: date, extension: "mov")
    }

    // `:` and `/` become `.`, so a date reads `2026-10-21 at 23.17.05`.
    private static func name(_ kind: String, device: String, date: Date, extension suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss"
        return "\(kind) - \(device) - \(formatter.string(from: date)).\(suffix)"
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: ".")
    }

    package static var desktop: URL? { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first }

    /// The preference as a path, without contacting its filesystem.
    package static var configuredScreenshotFolder: URL? {
        guard let value = HostPreferences.defaults.string(forKey: HostPreferences.screenShotSaveLocation), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
    }

    package static var preferredScreenshotFolder: URL {
        configuredScreenshotFolder ?? desktop ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }

    /// Uses an existing ScreenShotSaveLocation, then Desktop, then /private/tmp.
    package static func screenshotFolder() -> URL {
        if let folder = configuredScreenshotFolder {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return folder
            }
        }
        return desktop ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }

    /// The first of `name`, "name #2" through "name #99" that is free in `folder` and that `claim` accepts. A claim
    /// returning true holds the name against other claims from then on.
    @MainActor
    package static func unusedFile(in folder: URL, named name: String, lane: any CaptureLane = BlockingIOLane(),
                                   claim: (URL) -> Bool = { _ in true }) async throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            let exists = try await lane.run { FileManager.default.fileExists(atPath: candidate.path) }
            if !exists, claim(candidate) { return candidate }
        }
        throw SimulatorError.operation("Could not save \(name): \(folder.path) already has files of that name through #99.")
    }

    /// Moves the capture without overwriting, trying suffixes #2 through #99.
    /// A failure preserves the original file and reports its location.
    @MainActor
    package static func move(_ capture: URL, into folder: URL, named name: String, lane: any CaptureLane = BlockingIOLane(),
                             isReserved: @MainActor (URL) async -> Bool = { _ in false },
                             locations: Locations? = nil) async throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if await isReserved(candidate) { continue }
            do {
                try await lane.run { try relocate(capture, to: candidate, locations: locations) }
                return candidate
            } catch let error as POSIXError where error.code == .EEXIST {
                locations?.remove(candidate)
                continue
            } catch let error as CaptureLeftBehind {
                throw error
            } catch {
                throw SimulatorError.operation("Could not save \(name) in \(folder.path): \(error.localizedDescription) The capture is at \(capture.path).")
            }
        }
        throw SimulatorError.operation("Could not save \(name): \(folder.path) already has files of that name through #99. The capture is at \(capture.path).")
    }

    /// Writes `destination` through a private file beside it, replacing it atomically once `produce` has succeeded.
    @MainActor
    package static func write(to destination: URL, extension suffix: String, lane: any CaptureLane = BlockingIOLane(),
                              locations: Locations? = nil,
                              produce: (URL) async throws -> Void) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".neo-simulator-\(UUID().uuidString).\(suffix)")
        locations?.insert(temporary)
        locations?.insert(destination)
        try await lane.run { try createExclusively(temporary) }
        do {
            try await produce(temporary)
            try Task.checkCancellation()
            try await lane.run {
                guard rename(temporary.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        } catch {
            throw await removing(temporary, after: error, lane: lane)
        }
    }

    package static func createExclusively(_ file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
    }

    /// Moves a file without replacing what is at `destination`, which throws `EEXIST`. Failures leave the original where
    /// it is, except for ``CaptureLeftBehind``: the destination is then complete and the original was to go.
    ///
    /// A rename cannot leave the file half moved. Another volume needs a copy, which appears at `destination` only once
    /// it is whole, and only then does the original go. Nothing here repeats a step that failed.
    package static func relocate(_ source: URL, to destination: URL, renaming rename: (URL, URL) throws -> Void = renameExclusively,
                                 locations: Locations? = nil) throws {
        locations?.insert(destination)
        do { return try rename(source, destination) }
        catch let error as POSIXError where error.code == .EXDEV {}
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw POSIXError(.EEXIST) }
        try copy(source, to: destination, renaming: rename, locations: locations)
        do { try FileManager.default.removeItem(at: source) }
        catch { throw CaptureLeftBehind(destination: destination, original: source, cleanup: error) }
    }

    /// Copies a file to a private name beside `destination`, which it then takes whole or not at all.
    package static func copy(_ source: URL, to destination: URL, renaming rename: (URL, URL) throws -> Void = renameExclusively,
                             locations: Locations? = nil) throws {
        locations?.insert(destination)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".neo-simulator-\(UUID().uuidString).\(destination.pathExtension)")
        locations?.insert(staged)
        defer { locations?.remove(staged) }
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            try rename(staged, destination)
        } catch {
            throw removing(staged, after: error)
        }
    }

    /// Renames without replacing: throws `EEXIST` if `destination` is taken, and `EXDEV` if it is on another volume.
    package static func renameExclusively(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        let failure = errno
        guard failure == ENOTSUP || failure == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        // This volume cannot refuse a rename by itself.
        do { try FileManager.default.moveItem(at: source, to: destination) }
        catch CocoaError.fileWriteFileExists { throw POSIXError(.EEXIST) }
    }

    /// Removes a temporary file after `error`, and returns the error to report, which says if the file stayed behind.
    package static func removing(_ temporary: URL, after error: any Error) -> any Error {
        do { try FileManager.default.removeItem(at: temporary) }
        catch CocoaError.fileNoSuchFile {}
        catch let cleanup {
            return SimulatorError.operation("\(error.localizedDescription) Temporary file remains at \(temporary.path): \(cleanup.localizedDescription)")
        }
        return error
    }

    package static func removing(_ temporary: URL, after error: any Error, lane: any CaptureLane) async -> any Error {
        do { return try await lane.run { removing(temporary, after: error) } }
        catch { return error }
    }
}

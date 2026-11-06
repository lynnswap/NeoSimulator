import Foundation
import NeoSimulatorDeviceIO

package enum CaptureFile {
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

    /// Uses an existing ScreenShotSaveLocation, then Desktop, then /private/tmp.
    package static func screenshotFolder() -> URL {
        if let location = HostPreferences.defaults.string(forKey: HostPreferences.screenShotSaveLocation) {
            let path = NSString(string: location).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return desktop ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }

    /// The first of `name`, "name #2" through "name #99" that is free in
    /// `folder` and not reserved.
    package static func unusedFile(in folder: URL, named name: String, isReserved: (URL) -> Bool = { _ in false }) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path), !isReserved(candidate) { return candidate }
        }
        throw SimulatorError.operation("Could not save \(name): \(folder.path) already has files of that name through #99.")
    }

    /// Moves the capture without overwriting, trying suffixes #2 through #99.
    /// A failure preserves the original file and reports its location.
    package static func move(_ capture: URL, into folder: URL, named name: String,
                     isReserved: (URL) -> Bool = { _ in false }) throws -> URL {
        let base = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? name : "\(base) #\(number).\(suffix)")
            if isReserved(candidate) { continue }
            do {
                try FileManager.default.moveItem(at: capture, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw SimulatorError.operation("Could not save \(name) in \(folder.path): \(error.localizedDescription) The capture is at \(capture.path).")
            }
        }
        throw SimulatorError.operation("Could not save \(name): \(folder.path) already has files of that name through #99. The capture is at \(capture.path).")
    }

    @MainActor
    package static func write(to destination: URL, extension suffix: String,
                      produce: (URL) async throws -> Void) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".neo-simulator-\(UUID().uuidString).\(suffix)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        do {
            try await produce(temporary)
            try Task.checkCancellation()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch let cleanup {
                    throw SimulatorError.operation("\(error.localizedDescription) Temporary file remains at \(temporary.path): \(cleanup.localizedDescription)")
                }
            }
            throw error
        }
    }
}

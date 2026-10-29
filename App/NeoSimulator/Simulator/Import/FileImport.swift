import Foundation
import UniformTypeIdentifiers
import XcodeSimulatorHost

enum SimulatorFileImport {
    enum Kind { case application, media }

    /// Application bundles and `.ipa` packages, whose type has no `UTType` constant.
    static let applicationTypes = [UTType.applicationBundle] + [UTType(filenameExtension: "ipa")].compactMap { $0 }

    static func kind(of url: URL) throws -> Kind {
        if ["app", "ipa"].contains(url.pathExtension.lowercased()) { return .application }
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .vCard) {
            return .media
        }
        throw HostError.operation("Choose a simulator .app or .ipa, image, video, or vCard file")
    }

    @MainActor
    static func perform(_ urls: [URL], importFile: (URL, Kind) async throws -> Void) async throws {
        var completed: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                try Task.checkCancellation()
                try await importFile(url, kind(of: url))
                completed.append(url.lastPathComponent)
            } catch is CancellationError {
                hostLog("Import cancelled. Completed: \(completed.joined(separator: ", ")). Remaining files were not imported."
                        + failures.map { "\n" + $0 }.joined())
                throw CancellationError()
            } catch {
                // Only the temporary copy of an installed package remains.
                if case .cleanupFailed(_, .none, _) = error as? DeviceInspectorError { completed.append(url.lastPathComponent) }
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let summary = completed.isEmpty ? "No files were imported." : "Imported: \(completed.joined(separator: ", "))."
            throw HostError.operation(summary + "\n\n" + failures.joined(separator: "\n"))
        }
    }
}

import Foundation
import UniformTypeIdentifiers

enum SimulatorFileImport {
    enum Kind { case application, media }

    static func kind(of url: URL) throws -> Kind {
        if url.pathExtension.lowercased() == "app" { return .application }
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .vCard) {
            return .media
        }
        throw HostError.operation("Choose a simulator .app, image, video, or vCard file")
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
                hostLog("Import cancelled. Completed: \(completed.joined(separator: ", ")). Remaining files were not imported.")
                throw CancellationError()
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let summary = completed.isEmpty ? "No files were imported." : "Imported: \(completed.joined(separator: ", "))."
            throw HostError.operation(summary + "\n\n" + failures.joined(separator: "\n"))
        }
    }
}

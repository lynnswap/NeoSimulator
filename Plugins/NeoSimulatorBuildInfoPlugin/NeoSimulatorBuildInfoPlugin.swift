import Foundation
import PackagePlugin

@main
struct NeoSimulatorBuildInfoPlugin: BuildToolPlugin {
    private static let environmentKey = "NEOSIMULATOR_BUILD_VERSION"

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target is SourceModuleTarget else { return [] }

        let outputFile = context.pluginWorkDirectoryURL.appending(
            path: "NeoSimulatorBuildInfo.generated.swift"
        )
        let tool = try context.tool(named: "NeoSimulatorBuildInfoTool")
        var arguments = [
            "--output", outputFile.path,
            "--package-directory", context.package.directoryURL.path,
        ]
        let environmentVersion = ProcessInfo.processInfo.environment[Self.environmentKey]
            .flatMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : value
            }
        if let environmentVersion {
            arguments.append(contentsOf: ["--environment-version", environmentVersion])
        }

        return [
            .buildCommand(
                displayName: "Generate NeoSimulator build info",
                executable: tool.url,
                arguments: arguments,
                inputFiles: environmentVersion == nil
                    ? try Self.developmentIdentityInputFiles(
                        in: context.package.directoryURL
                    )
                    : [],
                outputFiles: [outputFile]
            )
        ]
    }

    private static func developmentIdentityInputFiles(
        in packageDirectory: URL
    ) throws -> [URL] {
        var inputs: [URL] = []
        try appendIdentityInput(
            packageDirectory.appending(path: "Package.swift"),
            to: &inputs
        )
        let resolved = packageDirectory.appending(path: "Package.resolved")
        if FileManager.default.fileExists(atPath: resolved.path) {
            try appendIdentityInput(resolved, to: &inputs)
        }
        for relativeDirectory in ["Plugins", "Sources"] {
            let directory = packageDirectory.appending(path: relativeDirectory)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true || values.isSymbolicLink == true else {
                    continue
                }
                try appendIdentityInput(url, to: &inputs)
            }
        }
        inputs.append(contentsOf: gitMetadataInputs(in: packageDirectory))
        return Dictionary(grouping: inputs, by: \.standardizedFileURL.path)
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
    }

    private static func appendIdentityInput(_ url: URL, to inputs: inout [URL]) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular:
            inputs.append(url)
        case .typeSymbolicLink:
            let target = url.resolvingSymlinksInPath()
            let targetAttributes = try FileManager.default.attributesOfItem(
                atPath: target.path
            )
            guard targetAttributes[.type] as? FileAttributeType == .typeRegular else {
                throw BuildInfoPluginError.message(
                    "build identity symlink must resolve to a regular file: \(url.path)"
                )
            }
            inputs.append(url)
            inputs.append(target)
        default:
            throw BuildInfoPluginError.message(
                "build identity input is not a regular file or symbolic link: \(url.path)"
            )
        }
    }

    private static func gitMetadataInputs(in packageDirectory: URL) -> [URL] {
        var inputs: [URL] = []
        if let headPath = gitOutput(
            ["rev-parse", "--git-path", "HEAD"],
            in: packageDirectory
        ) {
            inputs.append(gitURL(path: headPath, packageDirectory: packageDirectory))
        }
        let headLogURL = gitOutput(
            ["rev-parse", "--git-path", "logs/HEAD"],
            in: packageDirectory
        ).map { gitURL(path: $0, packageDirectory: packageDirectory) }
        if let headLogURL,
           FileManager.default.fileExists(atPath: headLogURL.path)
        {
            inputs.append(headLogURL)
        } else if let reference = gitOutput(
            ["symbolic-ref", "-q", "HEAD"],
            in: packageDirectory
        ),
            let referencePath = gitOutput(
                ["rev-parse", "--git-path", reference],
                in: packageDirectory
            )
        {
            inputs.append(gitURL(path: referencePath, packageDirectory: packageDirectory))
        }
        return inputs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func gitURL(path: String, packageDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return packageDirectory.appending(path: path)
    }

    private static func gitOutput(_ arguments: [String], in packageDirectory: URL) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", packageDirectory.path] + arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private enum BuildInfoPluginError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): message
        }
    }
}

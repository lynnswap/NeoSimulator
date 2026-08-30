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
        if let environmentVersion = ProcessInfo.processInfo.environment[Self.environmentKey] {
            arguments.append(contentsOf: ["--environment-version", environmentVersion])
        }

        return [
            .buildCommand(
                displayName: "Generate NeoSimulator build info",
                executable: tool.url,
                arguments: arguments,
                inputFiles: Self.identityInputFiles(in: context.package.directoryURL),
                outputFiles: [outputFile]
            )
        ]
    }

    private static func identityInputFiles(in packageDirectory: URL) -> [URL] {
        var inputs = [
            packageDirectory.appending(path: "Package.swift"),
        ]
        let resolved = packageDirectory.appending(path: "Package.resolved")
        if FileManager.default.fileExists(atPath: resolved.path) {
            inputs.append(resolved)
        }
        for relativeDirectory in ["Plugins", "Sources"] {
            let directory = packageDirectory.appending(path: relativeDirectory)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
                    values.isRegularFile == true || values.isSymbolicLink == true
                else { continue }
                inputs.append(url)
            }
        }
        inputs.append(contentsOf: gitAttributeInputs(in: packageDirectory))
        inputs.append(contentsOf: gitMetadataInputs(in: packageDirectory))
        return Dictionary(grouping: inputs, by: \.standardizedFileURL.path)
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
    }

    private static func gitAttributeInputs(in packageDirectory: URL) -> [URL] {
        let filename = ".gitattributes"
        var inputs = [packageDirectory.appending(path: filename)].filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }
        for relativeDirectory in ["Plugins", "Sources"] {
            let directory = packageDirectory.appending(path: relativeDirectory)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent == filename {
                guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
                    values.isRegularFile == true || values.isSymbolicLink == true
                else { continue }
                inputs.append(url)
            }
        }
        return inputs
    }

    private static func gitMetadataInputs(in packageDirectory: URL) -> [URL] {
        var inputs: [URL] = []
        for gitPath in ["HEAD", "index", "info/attributes"] {
            if let path = gitOutput(
                ["rev-parse", "--git-path", gitPath],
                in: packageDirectory
            ) {
                inputs.append(gitURL(path: path, packageDirectory: packageDirectory))
            }
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
        if let attributesPath = gitOutput(
            ["config", "--path", "--get", "core.attributesFile"],
            in: packageDirectory
        ) {
            inputs.append(gitURL(path: attributesPath, packageDirectory: packageDirectory))
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

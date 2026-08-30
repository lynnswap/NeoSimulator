import Foundation
import Testing

@testable import NeoSimulatorBuildInfoTool

@Suite
struct NeoSimulatorBuildInfoToolTests {
    @Test func environmentVersionWinsWithoutReadingGit() throws {
        let version = try BuildVersionResolver.resolve(
            environmentVersion: "  1.2.3  ",
            packageDirectory: URL(fileURLWithPath: "/package"),
            gitVersion: { _ in
                Issue.record("environment version must bypass Git")
                return nil
            }
        )

        #expect(version == "1.2.3")
    }

    @Test func gitIdentityIsRequiredWhenTheEnvironmentHasNoVersion() throws {
        let version = try BuildVersionResolver.resolve(
            environmentVersion: nil,
            packageDirectory: URL(fileURLWithPath: "/package"),
            gitVersion: { _ in "0.0.0-dev.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
        )
        #expect(version == "0.0.0-dev.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.resolve(
                environmentVersion: nil,
                packageDirectory: URL(fileURLWithPath: "/package"),
                gitVersion: { _ in nil }
            )
        }
    }

    @Test func developmentVersionSupportsGitObjectFormats() throws {
        let sha1Commit = String(repeating: "a", count: 40)
        let sha256Commit = String(repeating: "c", count: 64)
        let fingerprint = String(repeating: "b", count: 64)

        #expect(
            try BuildVersionResolver.developmentVersion(
                objectFormat: "sha1",
                commit: sha1Commit.uppercased(),
                sourceFingerprint: fingerprint.uppercased()
            ) == "0.0.0-dev.sha1.\(sha1Commit).source.\(fingerprint)"
        )
        #expect(
            try BuildVersionResolver.developmentVersion(
                objectFormat: "sha256",
                commit: sha256Commit,
                sourceFingerprint: fingerprint
            ) == "0.0.0-dev.sha256.\(sha256Commit).source.\(fingerprint)"
        )
    }

    @Test func developmentVersionRejectsInvalidGitIdentity() {
        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.developmentVersion(
                objectFormat: "sha512",
                commit: String(repeating: "a", count: 128),
                sourceFingerprint: String(repeating: "b", count: 64)
            )
        }
        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.developmentVersion(
                objectFormat: "sha1",
                commit: String(repeating: "a", count: 64),
                sourceFingerprint: String(repeating: "b", count: 64)
            )
        }
        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.developmentVersion(
                objectFormat: "sha256",
                commit: String(repeating: "a", count: 64),
                sourceFingerprint: "not-a-fingerprint"
            )
        }
    }

    @Test func generatedSourceEscapesAValidSwiftStringLiteral() {
        let source = BuildVersionResolver.generatedSource(
            version: #"1.2.3-"quoted"\path"#
        )

        #expect(source.contains(#"package static let version = "1.2.3-\"quoted\"\\path""#))
    }

    @Test func sourceFingerprintTracksPathsKindsAndContents() {
        let first = BuildVersionResolver.sourceFingerprint(
            records: [
                .init(
                    path: "Sources/New.swift",
                    kind: "regular",
                    contentDigest: Data("first contents".utf8)
                ),
            ]
        )
        let second = BuildVersionResolver.sourceFingerprint(
            records: [
                .init(
                    path: "Sources/New.swift",
                    kind: "regular",
                    contentDigest: Data("second contents".utf8)
                ),
            ]
        )
        #expect(first != second)
    }

    @Test func buildInputRecordsUseTheFilesystemRegardlessOfGitState() throws {
        let packageDirectory = FileManager.default.temporaryDirectory.appending(
            path: "NeoSimulatorBuildInfoToolTests-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: packageDirectory) }
        let sourceDirectory = packageDirectory.appending(path: "Sources/Example")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try "// package\n".write(
            to: packageDirectory.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let ignoredSource = sourceDirectory.appending(path: "Ignored.swift")
        try "enum Ignored {}\n".write(
            to: ignoredSource,
            atomically: true,
            encoding: .utf8
        )

        let records = try BuildVersionResolver.buildInputRecords(in: packageDirectory)

        #expect(
            Set(records.map(\.path)) == [
                "Package.swift",
                "Sources/Example/Ignored.swift",
            ]
        )
    }

    @Test func symlinkTargetContentsContributeToSourceFingerprint() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "NeoSimulatorBuildInfoToolTests-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let packageDirectory = temporaryRoot.appending(path: "Package")
        let sourceDirectory = packageDirectory.appending(path: "Sources/Example")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try "// package\n".write(
            to: packageDirectory.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let externalSource = temporaryRoot.appending(path: "External.swift")
        try "enum External { static let value = 1 }\n".write(
            to: externalSource,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: sourceDirectory.appending(path: "Linked.swift"),
            withDestinationURL: externalSource
        )

        let first = BuildVersionResolver.sourceFingerprint(
            records: try BuildVersionResolver.buildInputRecords(in: packageDirectory)
        )
        try "enum External { static let value = 2 }\n".write(
            to: externalSource,
            atomically: true,
            encoding: .utf8
        )
        let second = BuildVersionResolver.sourceFingerprint(
            records: try BuildVersionResolver.buildInputRecords(in: packageDirectory)
        )

        #expect(first != second)
    }
}

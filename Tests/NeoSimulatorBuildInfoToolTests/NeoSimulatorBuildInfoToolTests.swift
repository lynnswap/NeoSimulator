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

    @Test func developmentVersionIncludesCommitAndDirtyFingerprint() throws {
        let commit = String(repeating: "a", count: 40)
        let fingerprint = String(repeating: "b", count: 64)

        #expect(
            try BuildVersionResolver.developmentVersion(
                commit: commit,
                dirtyFingerprint: nil
            ) == "0.0.0-dev.\(commit)"
        )
        #expect(
            try BuildVersionResolver.developmentVersion(
                commit: commit.uppercased(),
                dirtyFingerprint: fingerprint.uppercased()
            ) == "0.0.0-dev.\(commit).dirty.\(fingerprint)"
        )
    }

    @Test func developmentVersionRejectsInvalidGitIdentity() {
        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.developmentVersion(
                commit: "not-a-commit",
                dirtyFingerprint: nil
            )
        }
        #expect(throws: BuildInfoToolError.self) {
            _ = try BuildVersionResolver.developmentVersion(
                commit: String(repeating: "a", count: 40),
                dirtyFingerprint: "not-a-fingerprint"
            )
        }
    }

    @Test func generatedSourceEscapesAValidSwiftStringLiteral() {
        let source = BuildVersionResolver.generatedSource(
            version: #"1.2.3-"quoted"\path"#
        )

        #expect(source.contains(#"package static let version = "1.2.3-\"quoted\"\\path""#))
    }

    @Test func dirtyFingerprintTracksChangedAndUntrackedSourceContents() {
        #expect(
            BuildVersionResolver.dirtyFingerprint(
                trackedDiff: Data(),
                untrackedRecords: []
            ) == nil
        )

        let firstTracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data("first diff".utf8),
            untrackedRecords: []
        )
        let secondTracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data("second diff".utf8),
            untrackedRecords: []
        )
        #expect(firstTracked != secondTracked)

        let firstUntracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data(),
            untrackedRecords: [
                .init(
                    path: "Sources/New.swift",
                    kind: "regular",
                    contentDigest: Data("first contents".utf8)
                ),
            ]
        )
        let secondUntracked = BuildVersionResolver.dirtyFingerprint(
            trackedDiff: Data(),
            untrackedRecords: [
                .init(
                    path: "Sources/New.swift",
                    kind: "regular",
                    contentDigest: Data("second contents".utf8)
                ),
            ]
        )
        #expect(firstUntracked != secondUntracked)
    }

    @Test func untrackedBuildInputsDoNotDependOnGitIgnoreRules() throws {
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

        let records = try BuildVersionResolver.untrackedInputRecords(
            trackedPathsData: Data("Package.swift\0".utf8),
            packageDirectory: packageDirectory
        )

        #expect(records.map(\.path) == ["Sources/Example/Ignored.swift"])
    }
}

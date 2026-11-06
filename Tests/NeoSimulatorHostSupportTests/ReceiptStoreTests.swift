import Foundation
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
import Testing


@Suite
struct ReceiptStoreTests {
    @MainActor @Test(arguments: [false, true])
    func asynchronousContendersWaitOrCancelWithoutTakingTheLock(cancel: Bool) async throws {
        let directory = try TemporaryTestDirectory()
        let store = try ReceiptStore(directoryURL: directory.url)
        let held = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await store.withExclusiveLock {
                held.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        defer { release.continuation.finish() }
        var holding = held.stream.makeAsyncIterator()
        await holding.next()
        let entered = AsyncStream<Void>.makeStream()
        var ran = false
        let contender = Task {
            entered.continuation.yield(())
            return try await store.withExistingExclusiveLock { ran = true; return 42 }
        }
        var entering = entered.stream.makeAsyncIterator()
        await entering.next()
        #expect(await !contender.ends(before: .now + .milliseconds(50)))
        #expect(!ran)
        if cancel {
            contender.cancel()
            #expect(await contender.ends(before: .now + .seconds(1)))
            await #expect(throws: CancellationError.self) { try await contender.value }
            #expect(!ran)
        }
        release.continuation.yield(())
        try await holder.value
        if !cancel { #expect(try await contender.value == 42 && ran) }
        #expect(try store.withExclusiveLock { 7 } == 7)
    }

    @Test func receiptRoundTripsAndDeletes() throws {
        let directory = try TemporaryTestDirectory()
        let store = try ReceiptStore(directoryURL: directory.url)
        let xcode = XcodeInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/Xcode_27.app"),
            version: try ToolVersion("27.0"),
            buildVersion: "27A5252f"
        )
        var receipt = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: ManagedPreferenceState(
                xcodeSession: .falseValue,
                deviceHubAutoStartSuppression: .absent
            )
        )
        receipt.expectedCurrent = .coreSimulator
        receipt.pending = PendingMutation(before: .coreSimulator, target: .deviceHub)

        try store.save(receipt)
        #expect(try store.load() == receipt)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.receiptURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.deleteReceipt()
        #expect(try store.load() == nil)
    }

    @Test func corruptReceiptIsNeverTreatedAsAbsent() throws {
        let directory = try TemporaryTestDirectory()
        let store = try ReceiptStore(directoryURL: directory.url)
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("not a plist".utf8).write(to: store.receiptURL)

        do {
            _ = try store.load()
            Issue.record("expected corrupt receipt to fail")
        } catch let error as HostOperationError {
            #expect(error.identifier == "receipt-decode")
            #expect(error.category == .configuration)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func invalidPendingJournalIsRejected() throws {
        let xcode = XcodeInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/Xcode_27.app"),
            version: try ToolVersion("27.0"),
            buildVersion: "27A5252f"
        )
        var wrongBefore = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        wrongBefore.pending = PendingMutation(
            before: .coreSimulator,
            target: .deviceHub
        )
        #expect(throws: HostOperationError.self) {
            try wrongBefore.validate()
        }

        var noOp = RestorationReceipt(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            xcode: xcode,
            original: .deviceHub
        )
        noOp.pending = PendingMutation(before: .deviceHub, target: .deviceHub)
        #expect(throws: HostOperationError.self) {
            try noOp.validate()
        }
    }

    @Test func nestedInvocationCannotAcquireTheSameLock() throws {
        let directory = try TemporaryTestDirectory()
        let store = try ReceiptStore(directoryURL: directory.url)

        try store.withExclusiveLock {
            do {
                try store.withExclusiveLock {}
                Issue.record("expected nested lock acquisition to fail")
            } catch let error as HostOperationError {
                #expect(error.identifier == "operation-lock")
                #expect(error.category == .temporary)
            }
        }
    }

    @Test func symbolicLinkCannotBecomeTheOperationLock() throws {
        let directory = try TemporaryTestDirectory()
        let store = try ReceiptStore(directoryURL: directory.url)
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let target = directory.url.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: store.lockURL,
            withDestinationURL: target
        )

        #expect(throws: HostOperationError.self) {
            try store.withExclusiveLock {}
        }
    }

    @Test func symbolicLinkCannotBecomeTheStateDirectory() throws {
        let directory = try TemporaryTestDirectory()
        let target = directory.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: target.path
        )
        let linkedState = directory.url.appendingPathComponent("linked-state", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedState,
            withDestinationURL: target
        )
        let store = try ReceiptStore(directoryURL: linkedState)

        #expect(throws: HostOperationError.self) {
            try store.withExclusiveLock {}
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }
}

import ABIBridge
import AppKit
import Darwin
import IOKit.hidsystem
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
@testable import NeoSimulatorUI
import Observation
import Synchronization
import Testing
import SwiftUI
import Combine
import XCTest
import XPC
@testable import NeoSimulatorManager
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens

extension SimulatorHostTests {
    @Test func sigtermHandsOffOnTheMainActor() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        let handoffs = AsyncStream<Void>.makeStream()
        let source = HostApplication.observeHandoverSignal {
            MainActor.assertIsolated()
            handoffs.continuation.yield(())
        }
        defer {
            source.cancel()
            signal(SIGTERM, previous)
            handoffs.continuation.finish()
        }
        try #require(kill(getpid(), SIGTERM) == 0)
        var events = handoffs.stream.makeAsyncIterator()
        #expect(await events.next() != nil)
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            source.setCancelHandler { @Sendable in finished.resume() }
            source.cancel()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledOpenCleansUpALateAttachmentWithoutClosingAnExistingScreen(_ preservingExisting: Bool) async throws {
        let display = TestDisplay()
        let entered = AsyncStream<Void>.makeStream()
        var events = entered.stream.makeAsyncIterator()
        var finish: CheckedContinuation<Void, Never>?
        let opening = Task {
            try await withScreenOpenCleanup(preservingExisting: preservingExisting, operation: {
                await withCheckedContinuation { continuation in
                    finish = continuation
                    entered.continuation.yield(())
                }
                return display
            }, cleanup: { display.disconnect() })
        }
        await events.next()
        opening.cancel()
        finish?.resume()
        do { _ = try await opening.value; Issue.record("A cancelled attachment was published") }
        catch is CancellationError {}
        #expect(display.disconnectCount == (preservingExisting ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func releasingAScreenReportsUnfinishedToolCleanupAndCanFinishItLater(_ failsCleanup: Bool) async throws {
        let controller = try makeController(TestDisplay())
        var release: CheckedContinuation<Void, Never>?
        var cleanedUp = false
        controller.session.run({
            await withCheckedContinuation { release = $0 }
            cleanedUp = true
            if failsCleanup { throw SimulatorError.operation("The capture's temporary file could not be removed") }
        }, failure: { _ in })
        try await wait { release != nil }
        let stopping = Task.immediate { try await controller.session.stop() }
        await #expect(throws: SimulatorError.self) { try await stopping.value }
        #expect(!cleanedUp)
        release?.resume()
        if failsCleanup {
            do {
                try await controller.session.stop()
                Issue.record("The stopped screen lost its cleanup failure")
            } catch {
                #expect(error.localizedDescription.contains("temporary file could not be removed"))
            }
        } else {
            try await controller.session.stop()
        }
        #expect(cleanedUp)
    }

    @Test func theOptionAlternatesFollowTheAppsActivationAsInSimulatorApp() throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        let window = try #require(controller.window)
        let pointer = try ToolbarPointer(controller)
        // SimToolbar tracks all active-app windows, not just the key window.
        // AppKit sends exit/enter events when the app deactivates/reactivates.
        #expect(pointer.area.options == [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect])
        // Resigning key releases device modifiers without clearing toolbar alternates.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        var releases = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if event.modifierFlags.isEmpty { releases += 1 }
            return event
        }
        defer { monitor.map(NSEvent.removeMonitor) }
        pointer.enter()
        pointer.hold(.option)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(releases == 1)
        #expect(pointer.faces == ButtonFace.optionAlternates)
        // Modifier changes in another app do not reach this toolbar.
        pointer.exit()
        #expect(pointer.faces == ButtonFace.normal)
        pointer.holdInAnotherApp([])
        pointer.holdInAnotherApp(.option)
        #expect(pointer.faces == ButtonFace.normal)
        pointer.enter()
        #expect(pointer.faces == ButtonFace.optionAlternates)
    }

    @Test func failedShutdownLeavesTheBootedDeviceUsable() async throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        var failure: Error?
        controller.session.run({ try await controller.session.shutDown() }, failure: { failure = $0 })
        for _ in 0..<3000 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failure != nil)
        #expect(controller.session.canPerformCommands)
    }

    /// Only disconnecting stops a running tool, and the window that could show its outcome goes with the session.
    @Test(.timeLimit(.minutes(1))) func onlyAToolStoppedByItsCallerSkipsTheFailureHandler() async throws {
        let controller = try makeController(TestDisplay())
        defer { controller.invalidate() }
        var failure: Error?
        func run(_ cause: CommandFailure.Interruption) async {
            controller.session.run({
                throw CommandFailure.interrupted(executable: URL(fileURLWithPath: "/simctl"), cause: cause, output: nil)
            }, failure: { failure = $0 })
            while controller.session.isBusy {
                await withCheckedContinuation { continuation in
                    withObservationTracking { _ = controller.session.isBusy } onChange: { continuation.resume() }
                }
            }
        }
        await run(.cancelled)
        #expect(failure == nil)
        await run(.timedOut(.seconds(30)))
        #expect((failure as? CommandFailure)?.interruption == .timedOut(.seconds(30)))
    }

    @Test func coreSimulatorLoadsReusePreparedMessages() async throws {
        async let first = CoreSimulatorInterface.load()
        async let second = CoreSimulatorInterface.load()
        let (original, concurrent) = try await (first, second)
        let later = try await CoreSimulatorInterface.load()
        #expect(original === concurrent && original === later)
    }

    @Test func nativeRuntimeJoinsPreparationAndRecoversAfterToolkitMismatch() async throws {
        async let first = makeRuntime()
        async let second = makeRuntime()
        let (runtime, joined) = try await (first, second)
        #expect(runtime === joined)

        let otherToolkit = runtime.uiXcodeURL.appendingPathComponent("DifferentXcode.app")
        await #expect(throws: DeviceIOError.self) {
            try await SimulatorPresentationRuntime.load(xcodeURL: runtime.xcodeURL, uiXcodeURL: otherToolkit)
        }
        let retried = try await SimulatorPresentationRuntime.load(xcodeURL: runtime.xcodeURL, uiXcodeURL: runtime.uiXcodeURL)
        #expect(retried.pasteboard.serviceName == "com.apple.CoreSimulator.SimPasteboardInterface")
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeDeviceSetDoesNotRefreshTheCatalogForBootProgressOrDeviceIO() async throws {
        let runtime = try await makeRuntime()
        let interface = runtime.io.coreSimulator
        let set = runtime.io.openDeviceSet()
        let context = try unsafe interface.sharedContext.unsafeInvoke(on: interface.serviceClass as AnyObject,
            runtime.xcodeURL.appendingPathComponent("Contents/Developer").path)
        let nativeSet = try unsafe interface.defaultDeviceSet.unsafeInvoke(on: context)
        let send = try await ABIRuntime.shared.resolve(
            .objc(.method("sendNotification:", as: ((NSDictionary) -> Void).self)),
            on: try #require(NSClassFromString("SimDeviceSet")))
        let changes = AsyncStream<Void>.makeStream()
        var refreshes = 0
        let token = try await set.observe {
            refreshes += 1
            changes.continuation.yield(())
        }
        defer { _ = set.stopObserving(token); changes.continuation.finish() }
        try unsafe send.unsafeInvoke(on: nativeSet, ["notification": "SimDeviceNotificationType_BootStatus"] as NSDictionary)
        try unsafe send.unsafeInvoke(on: nativeSet, ["notification": "device_io_notification"] as NSDictionary)
        try unsafe send.unsafeInvoke(on: nativeSet, ["notification": "device_state", "new_state": 3] as NSDictionary)
        var events = changes.stream.makeAsyncIterator()
        await events.next()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(refreshes == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeDeviceStateWaitUsesNotificationsAndCancels() async throws {
        let runtime = try await makeRuntime()
        let set = runtime.io.openDeviceSet()
        guard let device = try await set.refresh().first else { return }
        let interface = runtime.io.coreSimulator
        let context = try unsafe interface.sharedContext.unsafeInvoke(on: interface.serviceClass as AnyObject,
            runtime.xcodeURL.appendingPathComponent("Contents/Developer").path)
        let nativeSet = try unsafe interface.defaultDeviceSet.unsafeInvoke(on: context)
        let send = try await ABIRuntime.shared.resolve(.objc(.method("sendNotification:", as: ((NSDictionary) -> Void).self)),
                                                      on: try #require(NSClassFromString("SimDeviceSet")))
        let (reads, ready) = AsyncStream<Void>.makeStream()
        defer { ready.finish() }
        var changed = false
        let waiting = Task {
            try await set.waitForDevice(device.identifier, until: { _ in ready.yield(()); return changed },
                                        deadline: .now + .seconds(10))
        }
        defer { waiting.cancel() }
        var iterator = reads.makeAsyncIterator()
        await iterator.next()
        changed = true
        try unsafe send.unsafeInvoke(on: nativeSet, ["notification": "device_state"] as NSDictionary)
        #expect(try await waiting.value?.identifier == device.identifier)
        await iterator.next()

        let cancelled = Task {
            try await set.waitForDevice(device.identifier, until: { _ in ready.yield(()); return false },
                                        deadline: .now + .seconds(10))
        }
        await iterator.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    /// Only reads the guest. Each client here has its own context, and the only connection this cancels is its own.
    @Test(.timeLimit(.minutes(1)))
    func aDeviceClientIsSharedUntilItsOwnConnectionEnds() async throws {
        let runtime = try await makeRuntime()
        let set = runtime.io.openDeviceSet()
        #expect(try await set.client(withIdentifier: UUID().uuidString) == nil)
        #expect(try await set.client(withIdentifier: "not a UDID") == nil)
        guard let listed = try await set.refresh().first else { return }

        var device: SimulatorDevice? = try await joinedClient(in: set, identifier: listed.identifier)
        #expect(try await set.client(withIdentifier: listed.identifier) === device)
        #expect(device?.identity == listed.identity)
        _ = try await device?.currentState()
        _ = try await device?.supportedFeatures(DeviceCapabilities.allFeatures)

        let send = try await ABIRuntime.shared.resolve(
            .objc(.method("sendNotification:", as: ((NSDictionary) -> Void).self)),
            on: try #require(NSClassFromString("SimDeviceSet")))
        // A removal that the set does not show ends nothing.
        try autoreleasepool {
            let nativeSet = try #require((device?.object as? NSObject)?.value(forKey: "deviceSet") as? NSObject)
            try unsafe send.unsafeInvoke(on: nativeSet, ["notification": "device_removed"] as NSDictionary)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await set.client(withIdentifier: listed.identifier) === device)
        #expect(device?.state != 0)

        let released = try endConnection(of: try #require(device))
        let closedBy = ContinuousClock.now + .seconds(5)
        while try await set.client(withIdentifier: listed.identifier) === device {
            try #require(ContinuousClock.now < closedBy, "The closed device client was not retired.")
            try await Task.sleep(for: .milliseconds(10))
        }
        let replacement = try #require(try await set.client(withIdentifier: listed.identifier))
        #expect(replacement.channel === device?.channel)
        _ = try await replacement.currentState()
        do {
            _ = try await device?.currentState()
            Issue.record("A request went to a client that had ended.")
        } catch let failure as DeviceIOError where failure.category == .unavailable {}
        // What still holds the ended device keeps its context and set, which SimulatorKit needs while it has the device.
        let release = Task { for await _ in released {} }
        let releasedWhileHeld = await release.ends(before: .now + .milliseconds(300))
        #expect(!releasedWhileHeld)
        device = nil
        #expect(await release.ends(before: .now + .seconds(5)))
    }

    /// Reads, and registers with a set this test owns. A headless in-process host connects to no device and stops none.
    @Test(.timeLimit(.minutes(1)))
    func aTestingSetHeldWhileItOpensOpensOnceItAnswersAgain() async throws {
        let runtime = try await makeRuntime()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        HostPreferences.defaults.set(directory.path, forKey: HostPreferences.testingDeviceSetPath)
        defer { HostPreferences.defaults.removeObject(forKey: HostPreferences.testingDeviceSetPath) }

        // A raw call that outlives its deadline holds the set's worker, as a native call does.
        let channel = runtime.io.openDeviceSet(at: directory.path).channel
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "hold the set", limit: .milliseconds(20))) {
            try await channel.read("hold the set", limit: .milliseconds(20)) { release.wait() }
        }

        let host = try SimulatorScreenHost(runtime: runtime.io, conflicts: HostConflictMonitor(), headless: true, inProcess: true)
        let scans = AsyncStream<Void>.makeStream()
        host.onOwnershipChange = { _ in scans.continuation.yield() }
        try await host.start(attachingBootedDevices: false)
        // The start asks again, and is refused too, so only the set answering again is left to end this.
        var scan = scans.stream.makeAsyncIterator()
        await scan.next()
        #expect(!host.isObservingTestingSet)

        release.signal()
        for _ in 0..<3000 where !host.isObservingTestingSet { try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.isObservingTestingSet)
        try await host.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func stateWaitReportsDeadlineExpiration() async throws {
        let (host, device, _, cleanUp) = try await makeHostWithListedTestingDevice()
        defer { cleanUp() }
        do {
            _ = try await host.waitForDevice(device, until: { _ in false }, deadline: .now + .milliseconds(20))
            Issue.record("The state wait did not time out")
        } catch let error as DeviceIOError {
            #expect(error.identifier == "simulator-state-timeout")
        }
        try await host.stop()
    }

    @Test func aDevicesCopyReachesTheOtherDevicesWithoutEcho() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        var connections: [TestPasteboard] = []
        for index in 0..<3 {
            let display = TestDisplay()
            let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], device: "device-\(index)",
                                          pasteboard: pasteboard, pasteboardSync: sync)
            sessions.append(session)
            session.startPasteboardSync()
            connections.append(try #require(display.pasteboards.first))
        }
        defer { sessions.forEach { $0.disconnect() } }
        let (first, second, third) = (connections[0], connections[1], connections[2])
        func pushes() -> [Int] { connections.map { $0.transfers.count - 1 } }
        func copy(on connection: TestPasteboard, _ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            connection.send(.applied(generation: pasteboard.changeCount))
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(50))
        }

        // The other devices are sent the Mac pasteboard once the run loop
        // ends its pass, and the device that copied is not.
        copy(on: first, "first")
        #expect(pushes() == [0, 0, 0])
        try await settle()
        #expect(pushes() == [0, 1, 1])

        // Of copies in one pass, the last one's device is left out, and each
        // other device is sent the Mac pasteboard once.
        copy(on: first, "first again")
        copy(on: second, "second")
        try await settle()
        #expect(pushes() == [1, 1, 2])

        // A device whose copy the Mac pasteboard still holds is not sent it
        // back, also when another device's late report starts the exchange.
        first.send(.applied(generation: pasteboard.changeCount - 1))
        try await settle()
        #expect(pushes() == [1, 1, 3])
        // After a copy that could not be applied, it is sent again.
        second.send(.failedToApply(SimulatorError.operation("pasteboard communication failure")))
        first.send(.applied(generation: pasteboard.changeCount - 1))
        try await settle()
        #expect(pushes() == [1, 2, 4])

        sync.toggle()
        copy(on: third, "third")
        try await settle()
        #expect(pushes() == [1, 2, 4])
    }

    @Test func copiesReachSameUDIDDevicesInOtherSetsWithoutEcho() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        var connections: [TestPasteboard] = []
        for path in [nil, "/fixture/XCTestDevices"] as [String?] {
            let display = TestDisplay()
            let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], device: "same",
                deviceSetPath: path, pasteboard: pasteboard, pasteboardSync: sync)
            sessions.append(session)
            session.startPasteboardSync()
            connections.append(try #require(display.pasteboards.first))
        }
        defer { sessions.forEach { $0.disconnect() } }
        let before = connections.map { $0.transfers.count }
        pasteboard.clearContents()
        pasteboard.setString("copied", forType: .string)
        await withCheckedContinuation { continuation in
            connections[0].send(.applied(generation: pasteboard.changeCount))
            // This marker runs after the forwarding block scheduled in this run-loop mode.
            RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
        }
        #expect(connections[0].transfers.count == before[0])
        #expect(connections[1].transfers.count == before[1] + 1)
    }

    @Test func synchronizedDevicesReconnectAtOnceWhenTheConnectionCloses() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let display = TestDisplay()
        let session = try makeSession(display, features: [DeviceCapabilities.pasteboard], pasteboard: pasteboard,
                                      pasteboardSync: sync)
        sessions.append(session)
        defer { session.disconnect() }
        session.startPasteboardSync()
        let first = try #require(display.pasteboards.first)

        // Reconnection resumes synchronization without replacing the guest's pasteboard.
        first.send(.lostConnection)
        #expect(first.isDisconnected)
        #expect(display.pasteboards.count == 2)
        let second = try #require(display.pasteboards.last)
        #expect(second.automaticSync == [true])
        #expect(second.transfers.isEmpty)

        display.isBooted = false
        second.send(.lostConnection)
        #expect(display.pasteboards.count == 2)
        display.isBooted = true
        sync.toggle()
        session.transferPasteboard(.get) { _ in }
        #expect(display.pasteboards.count == 3)
        try #require(display.pasteboards.last).send(.lostConnection)
        #expect(display.pasteboards.count == 3)
    }

    @Test(arguments: [false, true])
    func anEarlierDeviceCopyGivesWayToALaterOneFromAnotherDevice(earlierWriteStarted: Bool) async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lynnswap.NeoSimulatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = MemoryPreferences()
        preferences.values[HostPreferences.pasteboardAutomaticSync] = true
        var sessions: [DeviceSession] = []
        let sync = PasteboardSync(preferences: preferences) { sessions }
        let (earlier, later) = (TestPasteboardTransport(), TestPasteboardTransport())
        // The later device's write waits behind its first send. The earlier device's waits too, or has started when
        // the later device copies.
        earlier.holdsSends = !earlierWriteStarted
        later.holdsSends = true
        for (name, transport) in [("earlier", earlier), ("later", later)] {
            sessions.append(try makeSession(TestDisplay(), features: [DeviceCapabilities.pasteboard], device: name,
                                            pasteboard: pasteboard, pasteboardSync: sync, pasteboardTransport: transport))
        }
        defer { sessions.forEach { $0.disconnect() } }
        sessions.forEach { $0.startPasteboardSync() }
        try await wait {
            [earlier, later].allSatisfy { $0.observations == 2 } && earlier.transfers == [.send] && later.heldSends == 1
                && earlier.heldSends == (earlierWriteStarted ? 0 : 1)
        }
        func mac() -> String? { pasteboard.string(forType: .string) }
        // Each write replaces the Mac pasteboard, as the CoreDevice transport's does, only if the connection still
        // lets it once the write is ready.
        func replaceMac(with text: String, if shouldReplace: @MainActor () -> Bool) -> Int? {
            guard shouldReplace() else { return nil }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }
        let reportEarlier = try #require(earlier.reportDeviceChange)
        let reportLater = try #require(later.reportDeviceChange)
        var resumeEarlier: CheckedContinuation<Void, Never>?
        reportEarlier { shouldReplace in
            if earlierWriteStarted { await withCheckedContinuation { resumeEarlier = $0 } }
            return replaceMac(with: "earlier copy", if: shouldReplace)
        }
        if earlierWriteStarted { try await wait { resumeEarlier != nil } }
        reportLater { shouldReplace in replaceMac(with: "later copy", if: shouldReplace) }

        // The earlier device's queue passes its copy first, which a send queued after it shows.
        if earlierWriteStarted {
            resumeEarlier?.resume()
        } else {
            earlier.holdsSends = false
            earlier.completeSend()
        }
        sessions[0].sendSynchronizedPasteboard()
        try await wait { earlier.transfers == [.send, .send] }
        later.holdsSends = false
        later.completeSend()

        // The later copy reaches the Mac, and from there the earlier device but not the later one.
        try await wait { earlier.transfers.count + later.transfers.count == 4 }
        #expect(mac() == "later copy" && earlier.transfers == [.send, .send, .send] && later.transfers == [.send])
    }

    @Test func restartRunsSimulatorAppStagesAndReportsTheFailedStage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("calls"), fail = directory.appendingPathComponent("fail")
        let simctl = directory.appendingPathComponent("simctl")
        try """
            #!/bin/sh
            echo "$1" >> "\(log.path)"
            case " $(cat "\(fail.path)" 2>/dev/null) " in
              *" $1 "*) echo "$1 failed" >&2; exit 1 ;;
            esac
            exit 0
            """.write(to: simctl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let tools = try DeviceTools(identifier: "test-device", xcodeURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
                                    simctl: simctl)
        func run(erasing: Bool, failing stage: String) async -> (calls: [String], error: String?, didStart: Bool) {
            try? FileManager.default.removeItem(at: log)
            try? stage.write(to: fail, atomically: true, encoding: .utf8)
            var message: String?
            var didStart = false
            do { try await tools.restart(erasing: erasing); didStart = true }
            catch { message = error.localizedDescription; didStart = error is DeviceRestartedWithFailure }
            let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            return (calls, message, didStart)
        }
        #expect(await run(erasing: false, failing: "").calls == ["shutdown", "boot"])
        #expect(await run(erasing: true, failing: "").calls == ["shutdown", "erase", "boot"])
        let shutdown = await run(erasing: true, failing: "shutdown")
        #expect(shutdown.calls == ["shutdown"])
        #expect(shutdown.error?.hasPrefix("Erase All Content and Settings failed while shutting down") == true)
        let erase = await run(erasing: true, failing: "erase")
        #expect(erase.didStart)
        #expect(erase.calls == ["shutdown", "erase", "boot"])
        #expect(erase.error?.contains("while erasing") == true)
        #expect(erase.error?.hasSuffix("The device was shut down and booted again.") == true)
        let boot = await run(erasing: false, failing: "boot")
        #expect(!boot.didStart)
        #expect(boot.calls == ["shutdown", "boot"])
        #expect(boot.error?.hasPrefix("Restart failed while booting") == true)
        #expect(boot.error?.hasSuffix("The device was shut down.") == true)
        let eraseAndBoot = await run(erasing: true, failing: "erase boot")
        #expect(eraseAndBoot.calls == ["shutdown", "erase", "boot"])
        #expect(eraseAndBoot.error?.contains("erase failed") == true)
        #expect(eraseAndBoot.error?.contains("boot failed") == true)
        #expect(eraseAndBoot.error?.hasSuffix("The device was shut down.") == true)
    }

    @Test func eraseAsksForConfirmationBeforeRestarting() async throws {
        var requests: [Bool] = []
        let controller = try makeController(TestDisplay(), onRestart: { _, erasing in requests.append(erasing) })
        defer { controller.invalidate() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        controller.perform(.eraseAllContentAndSettings)
        let sheet = try #require(window.attachedSheet)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(try #require(sheet.contentView)).compactMap { $0 as? NSButton }
        #expect(try #require(buttons.first { $0.title == "Erase" }).hasDestructiveAction)
        #expect(try #require(buttons.first { $0.title == "Cancel" }).keyEquivalent == "\u{1b}")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(requests.isEmpty)
        controller.perform(.eraseAllContentAndSettings)
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(requests == [true])
        controller.perform(.restart)
        #expect(requests == [true, false])
    }

    @Test func biometricShortcutsGoToTheKeyDevicesBiometrics() throws {
        _ = NSApplication.shared
        let menus = MenuController(application: nil)
        menus.install()
        defer { NSApp.mainMenu = nil }
        let features = try #require(NSApp.mainMenu?.items.first { $0.title == "Features" }?.submenu)
        func shortcuts(_ submenu: String) throws -> [String] {
            try #require(features.items.first { $0.title == submenu }?.submenu).items.map(\.keyEquivalent)
        }
        func device(_ feature: String) -> DeviceCapabilities {
            DeviceCapabilities(family: .iPhone, runtimeVersion: 0x1B_00_00, supportsFeature: { $0 == feature })
        }
        #expect(try shortcuts("Touch ID") == ["", "m", "n"] && shortcuts("Face ID") == ["", "", ""])
        #expect(try shortcuts("Optic ID") == ["", "", ""])
        // Face ID appears first and takes the shortcuts shared with Optic ID.
        menus.updateKeyEquivalents(for: device(DeviceCapabilities.faceID))
        #expect(try shortcuts("Touch ID") == ["", "", ""] && shortcuts("Face ID") == ["", "m", "n"])
        #expect(try shortcuts("Optic ID") == ["", "m", "n"])
        menus.updateVisibility(in: features, for: device(DeviceCapabilities.faceID))
        #expect(features.items.filter { !$0.isHidden }.prefix(2).map { $0.isSeparatorItem ? "-" : $0.title }
                == ["Face ID", "-"])
        menus.updateKeyEquivalents(for: device(DeviceCapabilities.touchID))
        #expect(try shortcuts("Touch ID") == ["", "m", "n"] && shortcuts("Face ID") == ["", "", ""])
        #expect(try shortcuts("Optic ID") == ["", "", ""])
        // Simulator.app assigns Shift-Command-I to Trigger iCloud Sync.
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        #expect(items.filter { $0.keyEquivalent == "i" && $0.keyEquivalentModifierMask == [.command, .shift] }
            .map(\.title) == ["Trigger iCloud Sync"])
    }

    @Test func opticIDPostsSimulatorAppsGuestNotifications() async throws {
        let display = TestDisplay()
        let controller = try makeController(display, family: .vision, features: [DeviceCapabilities.opticID])
        defer { controller.invalidate() }
        let enrolled = NSMenuItem()
        controller.perform(.opticIDEnrolled)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(DeviceCommand.command(.opticIDEnrolled).validate(enrolled, for: controller) && enrolled.state == .on)
        controller.perform(.opticIDMatching)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.opticIDNonMatching)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.faceIDMatching)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        controller.perform(.opticIDEnrolled)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(DeviceCommand.command(.opticIDEnrolled).validate(enrolled, for: controller) && enrolled.state == .off)
        #expect(display.postedNotifications == [
            "com.apple.BiometricKit.enrollmentChanged", "com.apple.BiometricKit_Sim.oyster.match",
            "com.apple.BiometricKit_Sim.oyster.nomatch", "com.apple.BiometricKit.enrollmentChanged",
        ])
    }

    @Test func simulateFallSetsAndPostsTheGuestsFallState() async throws {
        let display = TestDisplay()
        let controller = try makeController(display, family: .watch, features: [DeviceCapabilities.fallDetection])
        defer { controller.invalidate() }
        let name = "com.apple.sos.user-fell"
        for (command, state) in [(DeviceCommand.ID.fallUnresponsive, 3), (.fallRejected, 2), (.fallDismissed, 1),
                                 (.fallConfirmed, 0)] as [(DeviceCommand.ID, UInt64)] {
            controller.perform(command)
            for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
            #expect(display.notificationStates[name] == state, "\(command)")
        }
        #expect(display.postedNotifications == Array(repeating: name, count: 4))
        display.notificationError = SimulatorError.operation("refused")
        await #expect(throws: (any Error).self) { try await controller.session.simulateFall(.dismissed) }
        #expect(display.postedNotifications.count == 4)
        let other = TestDisplay()
        let otherController = try makeController(other, family: .watch, features: [], device: "other")
        defer { otherController.invalidate() }
        otherController.perform(.fallConfirmed)
        for _ in 0..<300 where otherController.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(other.notificationStates.isEmpty && other.postedNotifications.isEmpty)
    }

    @Test func slowAnimationsAndGraphicsQualityFollowTheAppsSettings() async throws {
        let keys = [HostPreferences.slowMotionAnimation, HostPreferences.graphicsQualityOverride]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let slowMotion = "com.apple.UIKit.SimulatorSlowMotionAnimationState"
        let quality = "com.apple.UIKit.ForceGraphicsQuality"
        let features: Set = [DeviceCapabilities.slowMotionStateful, DeviceCapabilities.graphicsQualityOverride]
        let display = TestDisplay()
        let controller = try makeController(display, features: features)
        defer { controller.invalidate() }
        let manager = SimulatorManagerModel(source: ManagerModelSource(devices: []))
        let screens = DeviceScreens(model: manager)
        let screen = screens.attach(controller, as: .simulator(udid: controller.session.device.identifier, deviceSetPath: nil))
        let slow = DeviceCommand.command(.toggleSlowAnimations)
        #expect(slow.stateTitle?(controller) == "Slow Animations" && slow.state?(controller) == .off)
        #expect(screen.supports("slowAnimations") && screen.isEnabled("slowAnimations"))
        screen.perform("slowAnimations")
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(slow.state?(controller) == .on)
        controller.perform(.graphicsQualityLow)
        for _ in 0..<300 where controller.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(DeviceCommand.command(.graphicsQualityLow).state?(controller) == .on)
        #expect(DeviceCommand.command(.graphicsQualityDefault).state?(controller) == .off)
        #expect(display.notificationStates == [slowMotion: 1, quality: 10])
        #expect(display.postedNotifications == [slowMotion, quality])

        display.notificationError = SimulatorError.operation("refused")
        await #expect(throws: (any Error).self) { try await controller.session.toggleSlowAnimations() }
        #expect(slow.state?(controller) == .on)

        let connected = TestDisplay()
        try await makeSession(connected, features: features).applyDebugSettings()
        #expect(connected.notificationStates == [slowMotion: 1, quality: 10])
        UserDefaults.standard.set(GraphicsQuality.deviceDefault.rawValue, forKey: HostPreferences.graphicsQualityOverride)
        let older = TestDisplay()
        try await makeSession(older, features: [DeviceCapabilities.graphicsQualityOverride]).applyDebugSettings()
        #expect(older.postedNotifications.isEmpty)

        // Simulator.app toggles slow animation in the frontmost app when the guest lacks support.
        let other = try makeController(older, features: [], device: "other")
        defer { other.invalidate() }
        let otherScreen = screens.attach(other, as: .simulator(udid: "other", deviceSetPath: nil))
        #expect(slow.stateTitle?(other) == "Toggle Slow Animations in Frontmost App" && slow.state?(other) == .off)
        otherScreen.perform("slowAnimations")
        for _ in 0..<300 where other.session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(older.notificationStates == [slowMotion: 0])
        #expect(!UserDefaults.standard.bool(forKey: HostPreferences.slowMotionAnimation))
    }

    @Test func colorOptionsShowTheDeviceStateAndReportDroppedChanges() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.perform(.colorBlendedLayers)
        controller.perform(.colorOffscreenRendered)
        #expect(display.caDebugOptions.map(\.rawValue).sorted() == [2, 17])
        let blended = DeviceCommand.command(.colorBlendedLayers)
        #expect(blended.state?(controller) == .on && DeviceCommand.command(.colorCopiedImages).state?(controller) == .off)
        // Validating a menu shows what the device last reported, without asking it.
        let reads = display.guestStateReads
        display.caDebugOptions.remove(.colorBlendedLayers)
        #expect(blended.state?(controller) == .on && display.guestStateReads == reads)
        // Another host may change it, so opening a menu reads it again.
        controller.session.refreshGuestState()
        #expect(blended.state?(controller) == .off)
        // CoreSimulator can silently drop writes; read back to detect that.
        display.droppedCADebugOptions = [.colorMisalignedImages]
        await #expect(throws: (any Error).self) { try await controller.session.toggle(.colorMisalignedImages) }
    }

    @Test func aHeldCallLeavesTheScreenAnsweringReportsWhatItKnowsAndReappliesOnlyWhatIsWantedNow() async throws {
        let key = HostPreferences.slowMotionAnimation
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(true, forKey: key)
        let slowMotion = "com.apple.UIKit.SimulatorSlowMotionAnimationState"
        let display = TestDisplay()
        let worker = HeldDeviceWorker(limit: .milliseconds(50))
        defer { worker.release() }
        let model = standaloneDeviceModel()
        model.follow(worker.channel)
        let controller = try makeController(display, features: [DeviceCapabilities.slowMotionStateful], model: model)
        defer { controller.invalidate() }
        let session = controller.session
        display.worker = worker
        worker.hold()

        let held = Task { try await session.toggleAppearance() }
        try await wait { worker.calls == ["toggle the device's appearance"] }
        let queued = Task { try await session.toggleAppearance() }
        await #expect(throws: DeviceOperationFailure.outcomeUnknown(operation: "toggle the device's appearance", cause: .timedOut(.milliseconds(50)))) {
            try await held.value
        }
        await #expect(throws: DeviceOperationFailure.notSent(operation: "toggle the device's appearance", heldBy: "toggle the device's appearance")) {
            try await queued.value
        }
        try await wait { model.unresponsiveOperation == "toggle the device's appearance" }

        // Nothing reaches the worker while it is held, or queues behind it.
        for _ in 0..<100 {
            await #expect(throws: DeviceOperationFailure.self) { try await session.toggleAppearance() }
        }
        session.refreshGuestState()
        #expect(worker.calls == ["toggle the device's appearance"])
        #expect(await worker.channel.unresolvedOperations().map(\.operation) == ["toggle the device's appearance"])
        #expect(display.appearanceToggles == 0)

        // The call's return is what recovers the device. What was refused is not sent, and what is wanted now is.
        worker.release()
        try await wait { model.unresponsiveOperation == nil }
        try await wait { display.notificationStates[slowMotion] == 1 && worker.calls.contains("read the device's state") }
        #expect(worker.calls.filter { $0 == "toggle the device's appearance" }.count == 1)
        #expect(display.appearanceToggles == 0)
    }

    /// The guest's bridge answers on a channel of its own. The device's model hears of a call held there, leaves refusing
    /// what would follow it to that channel, and recovers with each channel that answers again.
    @Test func aCallHeldOnTheGuestsBridgeMakesTheModelUnresponsiveWithoutItRefusingChanges() async throws {
        let device = DeviceAddress(identifier: UUID().uuidString, deviceSetPath: nil)
        let bridge = HeldDeviceWorker(limit: .milliseconds(50), channel: DeviceIOHub.shared.channel(for: .bridge(device)))
        defer { bridge.release() }
        let own = HeldDeviceWorker(limit: .milliseconds(50), channel: SimulatorDeviceChannel(scope: .device(device)))
        defer { own.release() }
        let model = standaloneDeviceModel()
        model.follow(own.channel)
        let recoveries = model.recoveries(), recovered = Mutex(0)
        let counting = Task { for await _ in recoveries { recovered.withLock { $0 += 1 } } }
        defer { counting.cancel() }
        bridge.hold()
        own.hold()

        await #expect(throws: DeviceOperationFailure.self) { try await bridge.read("read the guest's state") }
        try await wait { model.unresponsiveOperation == "read the guest's state" }
        try model.checkAcceptsChanges()
        await #expect(throws: DeviceOperationFailure.self) { try await own.read("look up a service") }
        try await wait { model.unresponsiveOperation == "look up a service" }

        // The bridge's requests can go on while the device's own channel still holds its call.
        bridge.release()
        try await wait { recovered.withLock { $0 } == 1 }
        #expect(model.unresponsiveOperation == "look up a service")
        own.release()
        try await wait { model.unresponsiveOperation == nil }
    }

    @Test func memoryWarningRewritesTheTriggerFileInPlaceAndReportsFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trigger = directory.appendingPathComponent("memory_warning_simulation")
        try Data("earlier".utf8).write(to: trigger)
        let file = try FileManager.default.attributesOfItem(atPath: trigger.path)[.systemFileNumber] as? Int
        let display = TestDisplay()
        display.memoryWarningURL = trigger
        let controller = try makeController(display)
        defer { controller.invalidate() }
        controller.perform(.simulateMemoryWarning)
        let attributes = try FileManager.default.attributesOfItem(atPath: trigger.path)
        #expect(attributes[.size] as? Int == 0)
        // CoreSimulator truncates this file in place.
        #expect(attributes[.systemFileNumber] as? Int == file)
        display.memoryWarningURL = directory.appendingPathComponent("missing/memory_warning_simulation")
        #expect(throws: (any Error).self) { try controller.session.simulateMemoryWarning() }
    }

    @Test func openSystemLogOpensTheDevicesLogOrReportsItsAbsence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = TestDisplay()
        display.logFolder = directory
        var opened: [URL] = []
        let controller = try makeController(display, openLog: { opened.append($0) })
        defer { controller.invalidate() }
        await #expect(throws: (any Error).self) { try await controller.session.openSystemLog() }
        #expect(opened.isEmpty)
        let log = directory.appendingPathComponent("system.log")
        try Data().write(to: log)
        controller.perform(.openSystemLog)
        for _ in 0..<200 where opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened == [log])
    }

    @Test(arguments: [false, true]) func gpuSelectionRewritesCoreSimulatorsPolicyAsSimulatorAppDoes(integrated: Bool) throws {
        _ = NSApplication.shared
        let defaults = try #require(MemoryDefaults(suiteName: nil))
        let menus = MenuController(application: nil, gpuPolicy: GPUPolicy(defaults: defaults))
        let file: NSMenu
        if integrated {
            file = NSMenu(title: "File")
            menus.addScreenCommands(file: file, edit: NSMenu(), view: NSMenu())
        } else {
            menus.install()
            file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        }
        defer { NSApp.mainMenu = nil }
        let titles = file.items.map { $0.isSeparatorItem ? "-" : $0.title }
        let index = try #require(titles.firstIndex(of: "GPU Selection"))
        if !integrated {
            #expect(titles[(index - 2)...(index + 2)] == ["Stop Recording", "-", "GPU Selection", "-", "Install App or Import Media…"])
        }
        let gpu = try #require(file.items[index].submenu)
        #expect(gpu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Automatic", "Prefer Integrated GPU", "Prefer Discrete GPU", "-", "Use External GPU When Available",
        ])
        let items = gpu.items.filter { !$0.isSeparatorItem }
        func checked() -> [String] { items.filter { menus.validateMenuItem($0) && $0.state == .on }.map(\.title) }
        func choose(_ title: String) throws -> [String]? {
            let item = try #require(items.first { $0.title == title })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            return defaults.stringArray(forKey: GPUPolicy.key)
        }
        // Simulator.app's default priority starts with automatic.
        #expect(checked() == ["Automatic"])
        #expect(try choose("Prefer Integrated GPU") == ["lowPower", "discrete", "external"])
        #expect(try choose("Use External GPU When Available") == ["external", "lowPower", "discrete"])
        #expect(checked() == ["Prefer Integrated GPU", "Use External GPU When Available"])
        #expect(try choose("Prefer Discrete GPU") == ["external", "discrete", "lowPower"])
        #expect(try choose("Automatic") == ["external", "automatic"])
        #expect(try choose("Use External GPU When Available") == ["automatic", "external"])
        #expect(checked() == ["Automatic"])
        // A legacy string is a one-item order; omit unsupported kinds.
        defaults.set("headless", forKey: GPUPolicy.key)
        #expect(checked().isEmpty)
        #expect(try choose("Prefer Discrete GPU") == ["discrete", "lowPower", "external"])
        let unavailable = MenuController(application: nil)
        #expect(!items.contains { unavailable.validateMenuItem($0) })
    }

    @Test func aRestoreWaitingForScenariosKeepsLaterChoicesAndEndedSessions() async throws {
        let restoreDefaults = removeLocationPreferences()
        defer { restoreDefaults() }
        HostPreferences.registerDefaults()
        // Scenario discovery can finish after a user changes the location.
        let display = TestDisplay()
        display.scenarios = Self.scenarios
        display.holdsScenarios = true
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let restore = Task.immediate { try await controller.session.restoreLocation() }
        controller.selectLocation(.none)
        display.releaseScenarios()
        try await restore.value
        #expect(controller.session.location == LocationSelection.none && display.appliedLocations == [.cleared])
        #expect(controller.session.locationScenarios == Self.scenarios)

        let ended = TestDisplay()
        ended.scenarios = Self.scenarios
        ended.holdsScenarios = true
        let session = try makeSession(ended)
        let endedRestore = Task.immediate { try await session.restoreLocation() }
        session.disconnect()
        ended.releaseScenarios()
        try await endedRestore.value
        #expect(session.locationScenarios.isEmpty && session.location == nil && ended.appliedLocations.isEmpty)
    }

    @Test func openSimulatorListsDevicesBySimulatorAppRules() throws {
        let devices = [
            availableDevice("a", "iPhone 17", runtime: "iOS 27.0", state: 3),
            availableDevice("b", "iPad", runtime: "iOS 27.0", state: 2),
            availableDevice("c", "iPhone 16", runtime: "iOS 26.5", state: 1),
        ]
        func items(_ devices: [AvailableDevice]) -> [NSMenuItem] {
            OpenSimulatorMenu.items(for: devices, hasWindow: { $0 == SimulatorDeviceIdentifier("a") }, action: #selector(NSText.copy(_:)),
                                    target: nil)
        }
        let runtimes = items(devices)
        #expect(runtimes.map(\.title) == ["iOS 27.0", "iOS 26.5"])
        #expect(runtimes.map(\.state) == [.mixed, .off])
        let first = try #require(runtimes[0].submenu?.items)
        #expect(first.map(\.title) == ["iPhone 17", "iOS 27.0 - iPhone 17", "iPad", "iOS 27.0 - iPad"])
        #expect(first.map(\.isAlternate) == [false, true, false, true])
        #expect(first.map(\.keyEquivalentModifierMask) == [[], .option, [], .option])
        #expect(first.map(\.state) == [.on, .on, .mixed, .mixed])
        #expect(first.map { $0.representedObject as? SimulatorDeviceIdentifier } == ["a", "a", "b", "b"].map { SimulatorDeviceIdentifier($0) })
        #expect(items(Array(devices.prefix(2))).map(\.title) == first.map(\.title))
    }

    @Test func lifetimeAlertsUseSimulatorAppTextAndDefaults() throws {
        _ = NSApplication.shared
        let close = DeviceLifetimeChoice.alert(quitting: false, keepsRunningByDefault: false)
        #expect(close.messageText == "Do you want to shutdown the simulated device?")
        #expect(close.informativeText == "When closing a window, you can either shut down the device or keep it running.")
        #expect(close.buttons.map(\.title) == ["Shut down", "Keep Running", "Cancel"])
        #expect(close.suppressionButton?.title == "Remember as the default close action.")
        #expect(close.buttons.map(\.keyEquivalent) == ["\r", "", "\u{1b}"])
        let quit = DeviceLifetimeChoice.alert(quitting: true, keepsRunningByDefault: true)
        #expect(quit.messageText == "Do you want to shut down the simulated devices?")
        #expect(quit.buttons.map(\.title) == ["Shut Down", "Keep Running", "Cancel"])
        #expect(quit.suppressionButton?.title == "Remember as the default quit action.")
        #expect(quit.buttons.map(\.keyEquivalent) == ["", "\r", "\u{1b}"])

        let key = "NeoSimulatorTestDetach-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(DeviceLifetimeChoice.choice(for: .alertThirdButtonReturn, of: quit, rememberingAs: key) == nil)
        #expect(DeviceLifetimeChoice.choice(for: .alertSecondButtonReturn, of: quit, rememberingAs: key) == .keepRunning)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        quit.suppressionButton?.state = .on
        #expect(DeviceLifetimeChoice.choice(for: .alertSecondButtonReturn, of: quit, rememberingAs: key) == .keepRunning)
        #expect(UserDefaults.standard.bool(forKey: key))
        #expect(DeviceLifetimeChoice.choice(for: .alertFirstButtonReturn, of: quit, rememberingAs: key) == .shutDown)
        #expect(!UserDefaults.standard.bool(forKey: key))
    }

    @Test func overlappingHoldsReleaseWhenTheLastEnds() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.invalidate() }
        let clock = ContinuousClock()
        let start = clock.now
        // Overlap the holds even on a slow runner.
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(1000)))
        try await Task.sleep(for: .milliseconds(50))
        controller.send(.hold(.button(.actionStaccato), for: .milliseconds(1000)))
        while display.events.count < 3, clock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clock.now - start >= .milliseconds(1050))
        try await Task.sleep(for: .milliseconds(100))
        #expect(display.events.map(\.state) == [.down, .down, .up])
    }
}

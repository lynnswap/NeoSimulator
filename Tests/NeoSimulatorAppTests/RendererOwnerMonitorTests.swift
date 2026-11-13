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

@Suite struct RendererOwnerMonitorTests {
    @Test func ownerLossRequestsCleanupOnceAndBoundsAStalledRunLoop() {
        let fixture = RendererOwnerMonitorFixture()
        let monitor = fixture.makeMonitor()
        #expect(fixture.state.withLock { $0.observedPID } == 123)
        #expect(fixture.state.withLock { $0.seconds } == nil)
        fixture.exitOwner()
        fixture.exitOwner()
        #expect(fixture.state.withLock { $0.cleanupRequests } == 1)
        #expect(fixture.state.withLock { $0.seconds } == 60)
        #expect(fixture.state.withLock { $0.forcedExits } == 0)
        // No run-loop cleanup is completed: only the independently controlled deadline progresses.
        fixture.expireDeadline()
        #expect(fixture.state.withLock { $0.forcedExits } == 1)
        monitor.stop()
        fixture.expireDeadline()
        #expect(fixture.state.withLock { $0.forcedExits } == 1)
        #expect(fixture.state.withLock { $0.observationCancelled && $0.deadlineCancelled })
    }

    @Test func normalCompletionAndLateCallbacksNeverStartOrForceOrphanCleanup() {
        let normal = RendererOwnerMonitorFixture()
        let monitor = normal.makeMonitor()
        monitor.stop()
        normal.exitOwner()
        normal.expireDeadline()
        #expect(normal.state.withLock { $0.cleanupRequests == 0 && $0.forcedExits == 0 && $0.seconds == nil })

        let orphan = RendererOwnerMonitorFixture()
        let completing = orphan.makeMonitor()
        orphan.exitOwner()
        completing.stop()
        orphan.expireDeadline()
        #expect(orphan.state.withLock { $0.cleanupRequests == 1 && $0.forcedExits == 0 && $0.deadlineCancelled })
    }
}

import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Foundation
import CoreAudio

package enum ReceiptStatus: Equatable {
    case unmanaged
    case managed(original: ManagedPreferenceState)
    case pendingBefore
    case pendingTarget
    case ambiguousIntermediate
    case conflict(expected: ManagedPreferenceState, observed: ManagedPreferenceState)

    package var hasConflict: Bool {
        if case .conflict = self {
            return true
        }
        return self == .ambiguousIntermediate
    }
}

package struct SimulatorRouteStatus: Equatable {
    package let preferences: ManagedPreferenceState
    package let receiptStatus: ReceiptStatus

}

/// Recovery metadata for the current session, without inspecting another app's preferences.
package struct SimulatorSessionStatus: Equatable {
    package let restorationAvailable: Bool
    package let allowsAutomaticHosting: Bool
}

package struct ModeChangeReport: Equatable {
    package let host: ResolvedHost
    package let didChangePreferences: Bool
    package let xcode: XcodeInstallation
    package let receiptURL: URL?
    package let terminatedDeviceHubCount: Int
    package let terminatedNeoHostCount: Int
}

package struct RestoreReport: Equatable {
    package let didRestore: Bool
    package let restoredState: ManagedPreferenceState?
    package let receiptURL: URL
    package let terminatedNeoHostCount: Int
}

import Foundation

/// SimulatorKit touch-indicator options backed by Simulator.app preferences.
/// Pinch pivot and edge indicators remain configurable through defaults write.
package enum TouchIndicator: CaseIterable {
    /// `.normalTouch`: where the pointer touches the screen.
    case singleTouches
    /// `.pinchTouches`: the two touches of an Option-drag pinch.
    case pinches
    /// `.pinchPivotPoint`: the pivot point of a pinch.
    case pinchPivotPoint
    /// `.edgeGestures`: Highlight Edge Gestures.
    case edgeGestures

    package var preferenceKey: String {
        switch self {
        case .singleTouches: HostPreferences.showSingleTouches
        case .pinches: HostPreferences.showPinches
        case .pinchPivotPoint: HostPreferences.showPinchPivotPoint
        case .edgeGestures: HostPreferences.highlightEdgeGestures
        }
    }

    /// Posted, with the preference store as its object, after a touch
    /// indicator's preference changes.
    package static let didChangeNotification = Notification.Name("dev.lynnswap.NeoSimulator.TouchIndicatorsDidChange")
}

/// Observes keys on the main actor until released. KVO includes external defaults writes
/// that UserDefaults.didChangeNotification omits.
package final class DefaultsObservation: NSObject {
    private let defaults: UserDefaults
    private let keys: [String]
    private let changed: @MainActor () -> Void

    package init(_ defaults: UserDefaults, keys: [String], changed: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.changed = changed
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, context: nil) }
    }

    deinit {
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    // A change in this process arrives on the thread that made it, and one
    // from another process on a thread of its own.
    package override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let changed = changed
        if Thread.isMainThread {
            MainActor.assumeIsolated { changed() }
        } else {
            DispatchQueue.main.async { changed() }
        }
    }
}

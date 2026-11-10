import ABIBridge
import Foundation

/// Pairs a discoverable CoreDevice with this Mac, asking for a code only when the device challenges it.
@MainActor
package enum CoreDeviceHostPairing {
    package typealias PINPrompt =
        @MainActor @Sendable (_ lastAttemptFailed: Bool, _ retryDelay: TimeInterval?) async throws -> String

    package static func pair(identifier: String, enteringPINUsing prompt: @escaping PINPrompt) async throws {
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: identifier)
        let pair = try await remote.type.resolve(
            .swift(
                .method(
                    "pair(enteringPINUsing:)",
                    as: ((NativeSwiftClosure<(Bool, Double?) async throws -> String>) async throws -> Void).self)))
        let callback = try makeCallback { (failed: Bool, delay: Double?) in
            try await prompt(failed, delay)
        }
        do { try await unsafe pair.unsafeInvoke(on: remote.object, callback) } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
    }

    // Swift 6.4.2 crashes when concrete callback arguments cross the async parameter pack initializer.
    private nonisolated static func makeCallback<First: Sendable, Second: Sendable>(
        _ body: @escaping @Sendable (First, Second) async throws -> String
    ) throws -> NativeSwiftClosure<(First, Second) async throws -> String> {
        try NativeSwiftClosure(body)
    }
}

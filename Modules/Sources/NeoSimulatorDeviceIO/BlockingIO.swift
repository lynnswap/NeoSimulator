import Dispatch

/// Runs file or pipe calls that can block for as long as another process chooses, on a queue of their own,
/// so they occupy neither the caller's executor nor a cooperative thread.
package func performBlockingIO<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue(label: "dev.lynnswap.NeoSimulator.blocking-io").async {
            continuation.resume(with: Result(catching: work))
        }
    }
}

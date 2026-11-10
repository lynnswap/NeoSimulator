import ABIBridge
import Foundation
import NeoSimulatorDeviceIO

/// Uses the same Finder action as Device Hub for physical devices.
@MainActor
package enum DeviceKitFinder {
    package static func showDevice(identifier: UUID) async throws {
        try await CoreDeviceRuntime.loadDeviceKit()
        let type = try await ABIRuntime.shared.resolve(.swift(.type("DeviceKit.ObservedDevice")))
        let make = try await type.resolve(
            .swift(
                .initializer(
                    "init(_:)",
                    as: ((UUID) async throws -> NativeSwiftValue).self)))
        typealias Completion = NativeSwiftClosure<@MainActor @Sendable (Result<Void, any Error>) -> Void>
        let show = try await type.resolve(
            .swift(
                .method(
                    "showInFinder(completionHandler:)",
                    as: ((Completion) -> Void).self)))
        let device = try await unsafe make.unsafeInvoke(identifier)
        defer { withExtendedLifetime(device) {} }
        let reply = AsyncThrowingStream<Void, any Error>.makeStream()
        let body: @MainActor @Sendable (Result<Void, any Error>) -> Void = {
            reply.continuation.yield(with: $0)
            reply.continuation.finish()
        }
        let callback = try await bridge(body).copyClosure(
            as: (@MainActor @Sendable (Result<Void, any Error>) -> Void).self)
        try unsafe show.unsafeInvoke(on: device, callback)
        var responses = reply.stream.makeAsyncIterator()
        _ = try await responses.next()
        try Task.checkCancellation()
    }

    private static func bridge<Value>(_ value: Value) async throws -> NativeSwiftValue {
        let array = try await ABIRuntime.shared.resolve(
            .swift(.type("Swift.Array", genericArguments: [.type(Value.self)])))
        let read = try await array.resolve(
            .swift(
                .getter(
                    "Swift.Array.subscript.getter : (Swift.Int) -> A",
                    as: ((Int) -> NativeSwiftValue).self)))
        return try unsafe read.unsafeInvoke(on: [value], 0)
    }
}

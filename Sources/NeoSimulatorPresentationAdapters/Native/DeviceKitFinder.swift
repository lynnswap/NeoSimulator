import ABIBridge
import Foundation
import NeoSimulatorDeviceIO

/// Uses the same Finder action as Device Hub for physical devices.
@MainActor
package enum DeviceKitFinder {
    package typealias Completion = NativeSwiftClosure<@MainActor @Sendable (Result<Void, any Error>) -> Void>

    package struct Bindings {
        let make: NativeSwiftFunction<(UUID) async throws -> NativeSwiftValue>
        let show: NativeSwiftMethod<(Completion) -> Void>

        package init(runtime: ABIRuntime) async throws {
            let type = try await runtime.resolve(.swift(.type("DeviceKit.ObservedDevice")))
            make = try await type.resolve(
                .swift(
                    .initializer(
                        "init(_:)", as: ((UUID) async throws -> NativeSwiftValue).self)))
            let result = try await runtime.resolve(
                .swift(
                    .type(
                        "Swift.Result",
                        genericArguments: [
                            .type(Void.self), .type((any Error).self),
                        ])))
            // Result is @frozen and passes its enum storage as integer chunks.
            let size = MemoryLayout<Result<Void, any Error>>.size
            let word = MemoryLayout<UInt>.size
            let fields =
                Array(repeating: NativeType.uint, count: size / word)
                + Array(repeating: NativeType.uint8, count: size % word)
            show = try await type.resolve(
                .swift(
                    .method(
                        "showInFinder(completionHandler:)", as: ((Completion) -> Void).self,
                        valueABIs: [result: try .structure(named: result.name, fields: fields)])))
        }
    }

    package static func showDevice(identifier: UUID) async throws {
        try await CoreDeviceRuntime.loadDeviceKit()
        let bindings = try await Bindings(runtime: .shared)
        let device = try await unsafe bindings.make.unsafeInvoke(identifier)
        defer { withExtendedLifetime(device) {} }
        let reply = AsyncThrowingStream<Void, any Error>.makeStream()
        let body: @MainActor @Sendable (Result<Void, any Error>) -> Void = {
            reply.continuation.yield(with: $0)
            reply.continuation.finish()
        }
        let callback = try await bridge(body).copyClosure(
            as: (@MainActor @Sendable (Result<Void, any Error>) -> Void).self)
        try unsafe bindings.show.unsafeInvoke(on: device, callback)
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

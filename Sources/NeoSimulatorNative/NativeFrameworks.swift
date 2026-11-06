import Darwin
import Foundation
import MachO

/// Why a private framework could not be loaded, or why what is loaded cannot be used.
package enum NativeRuntimeError: LocalizedError, Equatable, Sendable {
    case frameworkMissing(path: String)
    case loadFailed(path: String, detail: String)
    /// One process has one UI toolkit: Objective-C registration cannot be undone.
    case toolkitAlreadyLoaded(from: URL)
    case forbiddenImage(path: String)
    case imageFromOtherXcode(path: String)
    case pluginOutsideContext(path: String)

    package var errorDescription: String? {
        switch self {
        case .frameworkMissing(let path): "Missing framework at \(path)"
        case .loadFailed(let path, let detail): "Could not load \(path): \(detail)"
        case .toolkitAlreadyLoaded(let url): "SimulatorKit is already loaded from \(url.path)"
        case .forbiddenImage(let path): "Forbidden Device Hub component is loaded: \(path)"
        case .imageFromOtherXcode(let path): "Private simulator code came from a different Xcode: \(path)"
        case .pluginOutsideContext(let path): "The simulator UI plugin does not belong to an opened Xcode context: \(path)"
        }
    }
}

/// Loads private frameworks and the process's single UI toolkit on a dedicated serial queue.
/// Libraries remain mapped for the process lifetime. Serial check/load/record operations
/// prevent competing contexts from loading different toolkits.
package enum NativeFrameworks {
    private static let queue = DispatchQueue(label: "dev.lynnswap.NeoSimulator.native-frameworks")
    /// Only `queue` reads or writes these.
    private nonisolated(unsafe) static var uiToolkitXcodeURL: URL?
    private nonisolated(unsafe) static var contextXcodeURLs: Set<URL> = []
    private nonisolated(unsafe) static var validatedImageCount: UInt32 = 0
    private nonisolated(unsafe) static var validatedToolkit: URL?

    /// CoreSimulator's framework, which holds the classes every device context binds.
    package static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"

    /// Loads a framework's executable at `path`, a bundle or the executable itself.
    package static func load(_ path: String) async throws {
        try await onQueue { try loadSynchronously(path) }
    }

    /// Loads CoreSimulator, which reading devices needs and which chooses no UI toolkit.
    package static func loadCoreSimulator() async throws {
        try await load(coreSimulatorPath)
    }

    /// Loads the requested UI toolkit and records the device context.
    /// Without an explicit toolkit, uses the loaded toolkit or the context's Xcode.
    /// Registration is permanent even if later preparation fails.
    package static func loadUIToolkit(requested uiXcodeURL: URL?, context contextXcodeURL: URL) async throws -> URL {
        try await onQueue {
            let context = contextXcodeURL.resolvingSymlinksInPath()
            let requested = (uiXcodeURL ?? uiToolkitXcodeURL ?? context).resolvingSymlinksInPath()
            if let loaded = uiToolkitXcodeURL, loaded != requested {
                throw NativeRuntimeError.toolkitAlreadyLoaded(from: loaded)
            }
            try loadSynchronously(coreSimulatorPath)
            try loadSynchronously(requested.appendingPathComponent("Contents/SharedFrameworks/SimulatorKit.framework").path)
            uiToolkitXcodeURL = requested
            try loadSynchronously(requested.appendingPathComponent("Contents/Frameworks/IDEPlaygroundSimulator.framework").path)
            contextXcodeURLs.insert(context)
            return requested
        }
    }

    /// Loads DeviceKit from `xcodeURL`. DeviceKit and SimulatorKit come from one installation, so this also fixes the
    /// process's toolkit.
    package static func loadDeviceKit(from xcodeURL: URL) async throws {
        try await onQueue {
            let requested = xcodeURL.resolvingSymlinksInPath()
            if let loaded = uiToolkitXcodeURL, loaded != requested {
                throw NativeRuntimeError.toolkitAlreadyLoaded(from: loaded)
            }
            try loadSynchronously(requested.appendingPathComponent("Contents/SharedFrameworks/DeviceKit.framework/Versions/A/DeviceKit").path)
            uiToolkitXcodeURL = requested
        }
    }

    /// Checks that the toolkit stays fixed while allowing plugins of an opened device context. Images only ever join, so
    /// a count it has validated needs no second scan of the disk.
    package static func validateLoadedImages() async throws {
        try await onQueue {
            guard let toolkit = uiToolkitXcodeURL else { return }
            let count = _dyld_image_count()
            guard count != validatedImageCount || toolkit != validatedToolkit else { return }
            let prefix = toolkit.path + "/"
            for index in 0..<count {
                guard let pointer = _dyld_get_image_name(index) else { continue }
                let path = URL(fileURLWithPath: String(cString: pointer)).resolvingSymlinksInPath().path
                if path.contains("/DeviceHub.app/") { throw NativeRuntimeError.forbiddenImage(path: path) }
                if path.contains("/SimulatorKit.framework/") || path.contains("/IDEPlaygroundSimulator.framework/"),
                   !path.hasPrefix(prefix) {
                    throw NativeRuntimeError.imageFromOtherXcode(path: path)
                }
                if path.contains(".simdeviceui/"), !path.hasPrefix(prefix),
                   !contextXcodeURLs.contains(where: { path.hasPrefix($0.path + "/") }) {
                    throw NativeRuntimeError.pluginOutsideContext(path: path)
                }
            }
            validatedImageCount = count
            validatedToolkit = toolkit
        }
    }

    private static func loadSynchronously(_ path: String) throws {
        let executable: String
        if path.hasSuffix(".framework") || path.hasSuffix(".framework/") {
            guard let found = Bundle(path: path)?.executablePath else { throw NativeRuntimeError.frameworkMissing(path: path) }
            executable = found
        } else {
            executable = path
        }
        // Objective-C class registration and Apple runtime metadata outlive the handle.
        guard dlopen(executable, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            throw NativeRuntimeError.loadFailed(path: executable, detail: detail)
        }
    }

    private static func onQueue<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}

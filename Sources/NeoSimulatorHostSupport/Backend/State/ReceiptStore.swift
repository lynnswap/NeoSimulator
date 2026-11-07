import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

package struct ReceiptStore {
    package let directoryURL: URL
    package let receiptURL: URL
    package let lockURL: URL

    private let fileManager: FileManager

    private var hostSelectionURL: URL { directoryURL.appendingPathComponent("display-host.txt") }
    package func loadHostSelection() throws -> SimulatorHost? {
        let data: Data
        do { data = try Data(contentsOf: hostSelectionURL) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw HostOperationError.io("host-selection-read", "Could not read the saved display host: \(error.localizedDescription)") }
        guard let value = String(data: data, encoding: .utf8), let host = SimulatorHost(rawValue: value) else {
            throw HostOperationError.configuration("host-selection-decode", "The saved display host at \(hostSelectionURL.path) is invalid.")
        }
        return host
    }

    package func saveHostSelection(_ host: SimulatorHost) throws {
        try createDirectoryIfNeeded()
        do {
            try Data(host.rawValue.utf8).write(to: hostSelectionURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostSelectionURL.path)
        } catch {
            throw HostOperationError.io("host-selection-write", "Could not save the display host: \(error.localizedDescription)")
        }
    }

    package init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        let resolvedDirectory: URL
        if let directoryURL {
            resolvedDirectory = directoryURL
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw HostOperationError.cannotCreate(
                    "application-support",
                    "could not resolve the user Application Support directory"
                )
            }
            resolvedDirectory = applicationSupport
                .appendingPathComponent(ToolConstants.name, isDirectory: true)
        }

        self.directoryURL = resolvedDirectory.standardizedFileURL
        receiptURL = self.directoryURL.appendingPathComponent("state.plist")
        lockURL = self.directoryURL.appendingPathComponent("state.lock")
    }

    package func load() throws -> RestorationReceipt? {
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: receiptURL)
        } catch {
            throw HostOperationError.io(
                "receipt-read",
                "could not read \(receiptURL.path): \(error.localizedDescription)"
            )
        }

        do {
            let receipt = try PropertyListDecoder().decode(RestorationReceipt.self, from: data)
            try receipt.validate()
            return receipt
        } catch let error as HostOperationError {
            throw error
        } catch {
            throw HostOperationError.configuration(
                "receipt-decode",
                "could not decode \(receiptURL.path): \(error.localizedDescription)"
            )
        }
    }

    package func save(_ receipt: RestorationReceipt) throws {
        try receipt.validate()
        try createDirectoryIfNeeded()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw HostOperationError.software(
                "receipt-encode",
                "could not encode restoration receipt: \(error.localizedDescription)"
            )
        }

        do {
            try data.write(to: receiptURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: receiptURL.path
            )
        } catch {
            throw HostOperationError.io(
                "receipt-write",
                "could not write \(receiptURL.path): \(error.localizedDescription)"
            )
        }
    }

    package func deleteReceipt() throws {
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: receiptURL)
        } catch {
            throw HostOperationError.io(
                "receipt-delete",
                "could not remove \(receiptURL.path): \(error.localizedDescription)"
            )
        }
    }

    package func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = try acquireExclusiveLock(createIfNeeded: true)
        defer {
            releaseExclusiveLock(descriptor)
        }
        return try body()
    }

    package nonisolated(nonsending)
    func withExclusiveLock<T>(_ body: () async throws -> T) async throws -> T {
        let descriptor = try await waitForExclusiveLock(createIfNeeded: true)
        defer {
            releaseExclusiveLock(descriptor)
        }
        return try await body()
    }

    package nonisolated(nonsending)
    func withExistingExclusiveLock<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        let descriptor = try await waitForExclusiveLock(createIfNeeded: false)
        defer {
            releaseExclusiveLock(descriptor)
        }
        return try await body()
    }

    package func stateDirectoryExists() throws -> Bool {
        var metadata = stat()
        guard Darwin.lstat(directoryURL.path, &metadata) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw HostOperationError.io(
                "state-directory",
                "could not inspect \(directoryURL.path): \(String(cString: strerror(errno)))"
            )
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw HostOperationError.configuration(
                "state-directory",
                "state path is not a real directory: \(directoryURL.path)"
            )
        }
        return true
    }

    private func acquireExclusiveLock(createIfNeeded: Bool) throws -> Int32 {
        let descriptor = try openLock(createIfNeeded: createIfNeeded)
        do {
            guard try tryLock(descriptor) else {
                throw HostOperationError.temporary("operation-lock", "another \(ToolConstants.name) operation is in progress")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// The lock protects a cross-process transaction. Contention suspends its caller instead of rejecting ordinary
    /// concurrent status reads or blocking the caller's executor. Cancellation releases the waiting descriptor.
    private nonisolated(nonsending) func waitForExclusiveLock(createIfNeeded: Bool) async throws -> Int32 {
        try Task.checkCancellation()
        let descriptor = try openLock(createIfNeeded: createIfNeeded)
        do {
            if try tryLock(descriptor) { try Task.checkCancellation(); return descriptor }
            let watched = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard watched >= 0 else {
                throw HostOperationError.io("operation-lock", "could not observe \(lockURL.path): \(String(cString: strerror(errno)))")
            }
            let (unlocks, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: .funlock, queue: .global())
            source.setEventHandler { continuation.yield(()) }
            // The holder can unlock between our first attempt and the kernel's registration.
            source.setRegistrationHandler { continuation.yield(()) }
            source.setCancelHandler { Darwin.close(watched) }
            source.activate()
            defer { source.cancel(); continuation.finish() }
            for await _ in unlocks {
                try Task.checkCancellation()
                if try tryLock(descriptor) { try Task.checkCancellation(); return descriptor }
            }
            throw CancellationError()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func tryLock(_ descriptor: Int32) throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK || errno == EAGAIN { return false }
        throw HostOperationError.io("operation-lock", "could not lock \(lockURL.path): \(String(cString: strerror(errno)))")
    }

    private func openLock(createIfNeeded: Bool) throws -> Int32 {
        if createIfNeeded {
            try createDirectoryIfNeeded()
        } else if try !stateDirectoryExists() {
            throw HostOperationError.temporary(
                "operation-lock",
                "state changed while a read-only snapshot was being prepared; retry"
            )
        }

        var openFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        if createIfNeeded {
            openFlags |= O_CREAT
        }

        let descriptor = Darwin.open(
            lockURL.path,
            openFlags,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if !createIfNeeded, errno == ENOENT {
                throw HostOperationError.temporary(
                    "operation-lock",
                    "state directory exists without its operation lock; retry"
                )
            }
            throw HostOperationError.cannotCreate(
                "operation-lock",
                "could not open \(lockURL.path): \(String(cString: strerror(errno)))"
            )
        }

        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw HostOperationError.io(
                    "operation-lock",
                    "could not inspect \(lockURL.path): \(String(cString: strerror(errno)))"
                )
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw HostOperationError.configuration(
                    "operation-lock",
                    "operation lock is not a regular file: \(lockURL.path)"
                )
            }

            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func releaseExclusiveLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func createDirectoryIfNeeded() throws {
        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            var metadata = stat()
            guard Darwin.lstat(directoryURL.path, &metadata) == 0 else {
                throw HostOperationError.cannotCreate(
                    "state-directory",
                    "could not inspect \(directoryURL.path): \(String(cString: strerror(errno)))"
                )
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw HostOperationError.configuration(
                    "state-directory",
                    "state path is not a real directory: \(directoryURL.path)"
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch let error as HostOperationError {
            throw error
        } catch {
            throw HostOperationError.cannotCreate(
                "state-directory",
                "could not prepare \(directoryURL.path): \(error.localizedDescription)"
            )
        }
    }
}

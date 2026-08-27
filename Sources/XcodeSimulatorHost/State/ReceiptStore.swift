import Darwin
import Foundation

struct ReceiptStore {
    let directoryURL: URL
    let receiptURL: URL
    let lockURL: URL

    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        let resolvedDirectory: URL
        if let directoryURL {
            resolvedDirectory = directoryURL
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CLIError.cannotCreate(
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

    func load() throws -> RestorationReceipt? {
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: receiptURL)
        } catch {
            throw CLIError.io(
                "receipt-read",
                "could not read \(receiptURL.path): \(error.localizedDescription)"
            )
        }

        do {
            let receipt = try PropertyListDecoder().decode(RestorationReceipt.self, from: data)
            try receipt.validate()
            return receipt
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.configuration(
                "receipt-decode",
                "could not decode \(receiptURL.path): \(error.localizedDescription)"
            )
        }
    }

    func save(_ receipt: RestorationReceipt) throws {
        try receipt.validate()
        try createDirectoryIfNeeded()

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw CLIError.software(
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
            throw CLIError.io(
                "receipt-write",
                "could not write \(receiptURL.path): \(error.localizedDescription)"
            )
        }
    }

    func deleteReceipt() throws {
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: receiptURL)
        } catch {
            throw CLIError.io(
                "receipt-delete",
                "could not remove \(receiptURL.path): \(error.localizedDescription)"
            )
        }
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try createDirectoryIfNeeded()

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CLIError.cannotCreate(
                "operation-lock",
                "could not open \(lockURL.path): \(String(cString: strerror(errno)))"
            )
        }
        defer {
            Darwin.close(descriptor)
        }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw CLIError.io(
                "operation-lock",
                "could not inspect \(lockURL.path): \(String(cString: strerror(errno)))"
            )
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CLIError.configuration(
                "operation-lock",
                "operation lock is not a regular file: \(lockURL.path)"
            )
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw CLIError.temporary(
                    "operation-lock",
                    "another \(ToolConstants.name) operation is in progress"
                )
            }
            throw CLIError.io(
                "operation-lock",
                "could not lock \(lockURL.path): \(String(cString: strerror(errno)))"
            )
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
        }

        return try body()
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
                throw CLIError.cannotCreate(
                    "state-directory",
                    "could not inspect \(directoryURL.path): \(String(cString: strerror(errno)))"
                )
            }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw CLIError.configuration(
                    "state-directory",
                    "state path is not a real directory: \(directoryURL.path)"
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.cannotCreate(
                "state-directory",
                "could not prepare \(directoryURL.path): \(error.localizedDescription)"
            )
        }
    }
}

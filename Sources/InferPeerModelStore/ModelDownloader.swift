import Foundation

/// Secure transport, resume, size, and local-file failures.
public enum ModelDownloadError: Error, Equatable, Sendable {
    case insecureURL
    case invalidResponse
    case serverRejected(statusCode: Int)
    case invalidResumeResponse
    case receivedTooManyBytes
    case incompleteDownload(expected: UInt64, actual: UInt64)
    case fileSystemFailure
}

/// Download transport used by the package-owned installation pipeline.
public protocol ModelFileDownloading: Sendable {
    func download(
        _ file: ModelDownloadFile,
        to partialURL: URL,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64
}

/// HTTPS downloader that resumes from durable partial-file length using Range.
public actor ResumableHTTPSModelDownloader: ModelFileDownloading {
    private let session: URLSession
    private let chunkSize = 1_048_576

    /// Creates a downloader from a host-selectable URL session configuration.
    public init(configuration: URLSessionConfiguration = .default) {
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    /// Downloads or resumes one exact file into a durable partial path.
    public func download(
        _ file: ModelDownloadFile,
        to partialURL: URL,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64 {
        guard file.url.scheme?.lowercased() == "https" else {
            throw ModelDownloadError.insecureURL
        }
        let existingBytes = try Self.preparePartialFile(partialURL, expected: file.byteCount)
        if existingBytes == file.byteCount {
            progress(existingBytes)
            return existingBytes
        }
        var request = URLRequest(url: file.url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        let startOffset = try Self.startOffset(
            response: response,
            requestedOffset: existingBytes
        )
        let handle = try Self.open(partialURL, startOffset: startOffset)
        defer { try? handle.close() }
        return try await write(
            bytes,
            to: handle,
            startOffset: startOffset,
            expected: file.byteCount,
            progress: progress
        )
    }

    private func write(
        _ bytes: URLSession.AsyncBytes,
        to handle: FileHandle,
        startOffset: UInt64,
        expected: UInt64,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws -> UInt64 {
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var completed = startOffset
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count == chunkSize {
                completed = try Self.flush(
                    buffer, to: handle, completed: completed, expected: expected)
                buffer.removeAll(keepingCapacity: true)
                progress(completed)
            }
        }
        if !buffer.isEmpty {
            completed = try Self.flush(buffer, to: handle, completed: completed, expected: expected)
            progress(completed)
        }
        guard completed == expected else {
            throw ModelDownloadError.incompleteDownload(expected: expected, actual: completed)
        }
        return completed
    }

    private static func preparePartialFile(_ url: URL, expected: UInt64) throws -> UInt64 {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw ModelDownloadError.fileSystemFailure
                }
                return 0
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw ModelDownloadError.fileSystemFailure
            }
            let count = size.uint64Value
            if count <= expected { return count }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.close()
            return 0
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.fileSystemFailure
        }
    }

    private static func startOffset(response: URLResponse, requestedOffset: UInt64) throws -> UInt64
    {
        guard let response = response as? HTTPURLResponse else {
            throw ModelDownloadError.invalidResponse
        }
        if requestedOffset == 0, response.statusCode == 200 { return 0 }
        if requestedOffset > 0, response.statusCode == 200 { return 0 }
        guard response.statusCode == 206 else {
            throw ModelDownloadError.serverRejected(statusCode: response.statusCode)
        }
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
            range.hasPrefix("bytes \(requestedOffset)-")
        else {
            throw ModelDownloadError.invalidResumeResponse
        }
        return requestedOffset
    }

    private static func open(_ url: URL, startOffset: UInt64) throws -> FileHandle {
        do {
            let handle = try FileHandle(forWritingTo: url)
            if startOffset == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                try handle.seek(toOffset: startOffset)
            }
            return handle
        } catch {
            throw ModelDownloadError.fileSystemFailure
        }
    }

    private static func flush(
        _ data: Data,
        to handle: FileHandle,
        completed: UInt64,
        expected: UInt64
    ) throws -> UInt64 {
        guard let count = UInt64(exactly: data.count), completed <= expected - min(expected, count)
        else {
            throw ModelDownloadError.receivedTooManyBytes
        }
        do {
            try handle.write(contentsOf: data)
            return completed + count
        } catch {
            throw ModelDownloadError.fileSystemFailure
        }
    }
}

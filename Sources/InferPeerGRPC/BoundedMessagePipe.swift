import Foundation

final class BoundedMessagePipe<Element: Sendable>: @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<Element, any Error>

    private let lock = NSLock()
    private let continuation: Stream.Continuation
    private let stream: Stream
    private let capacity: Int
    private var isClosed = false
    private var isClaimed = false

    init(capacity: Int) {
        self.capacity = capacity
        let pair = Stream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ element: Element) throws {
        try lock.withLock {
            guard !isClosed else { throw InferPeerGRPCError.sessionClosed }
            switch continuation.yield(element) {
            case .enqueued:
                return
            case .dropped:
                terminateLocked(throwing: InferPeerGRPCError.bufferExhausted)
                throw InferPeerGRPCError.bufferExhausted
            case .terminated:
                isClosed = true
                throw InferPeerGRPCError.sessionClosed
            @unknown default:
                terminateLocked(throwing: InferPeerGRPCError.internalFailure)
                throw InferPeerGRPCError.internalFailure
            }
        }
    }

    func claimedStream(bufferingLimit: Int) -> Stream {
        lock.withLock {
            guard bufferingLimit > 0, bufferingLimit <= capacity else {
                return Self.failedStream(InferPeerGRPCError.invalidBufferLimit)
            }
            guard !isClaimed else {
                return Self.failedStream(InferPeerGRPCError.streamAlreadyConsumed)
            }
            isClaimed = true
            return stream
        }
    }

    func internalStream() -> Stream {
        stream
    }

    func finish() {
        lock.withLock { terminateLocked(throwing: nil) }
    }

    func fail(_ error: any Error) {
        lock.withLock { terminateLocked(throwing: error) }
    }

    private func terminateLocked(throwing error: (any Error)?) {
        guard !isClosed else { return }
        isClosed = true
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private static func failedStream(_ error: any Error) -> Stream {
        Stream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

actor HandshakeLatch<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?

    func wait() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func succeed(_ value: Value) {
        resolve(.success(value))
    }

    func fail(_ error: any Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
    }
}

import Foundation
import InferPeerCore
import InferPeerProtocol

final class BoundedMessagePipe<Element: Sendable>: @unchecked Sendable {
    typealias Stream = TransportMessageStream<Element>

    private struct QueuedElement {
        let value: Element
        let isControl: Bool
    }

    private struct PendingSend {
        let id: UUID
        let element: QueuedElement
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingReceive {
        let id: UUID
        let continuation: CheckedContinuation<Element?, any Error>
    }

    private let lock = NSLock()
    private let capacity: Int
    private let regularCapacity: Int
    private let isControl: @Sendable (Element) -> Bool
    private var queue: [QueuedElement] = []
    private var pendingSends: [PendingSend] = []
    private var pendingReceive: PendingReceive?
    private var terminalError: (any Error)?
    private var isAccepting = true
    private var isClaimed = false

    init(
        capacity: Int,
        isControl: @escaping @Sendable (Element) -> Bool = { _ in true }
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        regularCapacity = max(0, capacity - 1)
        self.isControl = isControl
    }

    func send(_ element: Element) async throws {
        let sendID = UUID()
        let cancellation = PipeCancellation()
        try await withTaskCancellationHandler(
            operation: {
                try await waitToSend(element, id: sendID, cancellation: cancellation)
            },
            onCancel: {
                cancellation.cancel()
                cancelSend(sendID)
            }
        )
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
            return makeStream()
        }
    }

    func internalStream() -> Stream {
        lock.withLock {
            guard !isClaimed else {
                return Self.failedStream(InferPeerGRPCError.streamAlreadyConsumed)
            }
            isClaimed = true
            return makeStream()
        }
    }

    func finish() {
        lock.withLock {
            guard isAccepting else { return }
            isAccepting = false
            failPendingSendsLocked(with: InferPeerGRPCError.sessionClosed)
            drainLocked()
        }
    }

    func fail(_ error: any Error) {
        lock.withLock {
            guard isAccepting else { return }
            isAccepting = false
            terminalError = error
            queue.removeAll()
            failPendingSendsLocked(with: error)
            resolveTerminalReceiveLocked()
        }
    }

    private func receive() async throws -> Element? {
        let receiveID = UUID()
        let cancellation = PipeCancellation()
        return try await withTaskCancellationHandler(
            operation: { try await waitToReceive(id: receiveID, cancellation: cancellation) },
            onCancel: {
                cancellation.cancel()
                cancelReceive(receiveID)
            }
        )
    }

    private func makeStream() -> Stream {
        Stream { [self] in try await receive() }
    }

    private func waitToSend(
        _ element: Element,
        id: UUID,
        cancellation: PipeCancellation
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            registerSend(
                element,
                id: id,
                cancellation: cancellation,
                continuation: continuation
            )
        }
    }

    private func registerSend(
        _ element: Element,
        id: UUID,
        cancellation: PipeCancellation,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        lock.withLock {
            guard !cancellation.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            guard isAccepting else {
                continuation.resume(throwing: terminalError ?? InferPeerGRPCError.sessionClosed)
                return
            }
            pendingSends.append(
                PendingSend(
                    id: id,
                    element: QueuedElement(value: element, isControl: isControl(element)),
                    continuation: continuation
                ))
            drainLocked()
        }
    }

    private func waitToReceive(
        id: UUID,
        cancellation: PipeCancellation
    ) async throws -> Element? {
        try await withCheckedThrowingContinuation { continuation in
            registerReceive(
                id: id,
                cancellation: cancellation,
                continuation: continuation
            )
        }
    }

    private func registerReceive(
        id: UUID,
        cancellation: PipeCancellation,
        continuation: CheckedContinuation<Element?, any Error>
    ) {
        lock.withLock {
            guard !cancellation.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            guard pendingReceive == nil else {
                continuation.resume(throwing: InferPeerGRPCError.streamAlreadyConsumed)
                return
            }
            pendingReceive = PendingReceive(id: id, continuation: continuation)
            drainLocked()
        }
    }

    private func drainLocked() {
        while deliverQueuedElementLocked() || admitPendingSendLocked() {}
        resolveTerminalReceiveLocked()
    }

    private func deliverQueuedElementLocked() -> Bool {
        guard let receiver = pendingReceive, !queue.isEmpty else { return false }
        pendingReceive = nil
        receiver.continuation.resume(returning: queue.removeFirst().value)
        return true
    }

    private func admitPendingSendLocked() -> Bool {
        guard let pending = pendingSends.first else { return false }
        if let receiver = pendingReceive {
            pendingReceive = nil
            pendingSends.removeFirst()
            receiver.continuation.resume(returning: pending.element.value)
            pending.continuation.resume()
            return true
        }
        guard permits(pending.element) else { return false }
        pendingSends.removeFirst()
        queue.append(pending.element)
        pending.continuation.resume()
        return true
    }

    private func permits(_ element: QueuedElement) -> Bool {
        guard queue.count < capacity else { return false }
        return element.isControl || queue.lazy.filter({ !$0.isControl }).count < regularCapacity
    }

    private func resolveTerminalReceiveLocked() {
        guard !isAccepting, queue.isEmpty, let receiver = pendingReceive else { return }
        pendingReceive = nil
        if let terminalError {
            receiver.continuation.resume(throwing: terminalError)
        } else {
            receiver.continuation.resume(returning: nil)
        }
    }

    private func failPendingSendsLocked(with error: any Error) {
        let sends = pendingSends
        pendingSends.removeAll()
        sends.forEach { $0.continuation.resume(throwing: error) }
    }

    private func cancelSend(_ id: UUID) {
        lock.withLock {
            guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
            let pending = pendingSends.remove(at: index)
            pending.continuation.resume(throwing: CancellationError())
            drainLocked()
        }
    }

    private func cancelReceive(_ id: UUID) {
        lock.withLock {
            guard pendingReceive?.id == id else { return }
            let receiver = pendingReceive
            pendingReceive = nil
            receiver?.continuation.resume(throwing: CancellationError())
        }
    }

    private static func failedStream(_ error: any Error) -> Stream {
        Stream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

private final class PipeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

enum MessagePriority {
    static func clientRequest(_ request: InferPeer_V1_ClientSessionRequest) -> Bool {
        if case .submit = request.payload { return false }
        return true
    }

    static func clientResponse(_ response: InferPeer_V1_ClientSessionResponse) -> Bool {
        guard case .generationEvent(let event) = response.payload else { return true }
        return event.isControl
    }

    static func workerRequest(_ request: InferPeer_V1_WorkerSessionRequest) -> Bool {
        guard case .generationEvent(let event) = request.payload else { return true }
        return event.isControl
    }

    static func workerResponse(_: InferPeer_V1_WorkerSessionResponse) -> Bool {
        true
    }
}

private extension InferPeer_V1_GenerationEvent {
    var isControl: Bool {
        if case .textDelta = payload { return false }
        return true
    }
}

actor HandshakeLatch<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Value, any Error>)?

    func wait() async throws -> Value {
        if let result {
            return try result.get()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = (waiterID, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
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
            waiter.continuation.resume(with: result)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard waiter?.id == waiterID else { return }
        let continuation = waiter?.continuation
        waiter = nil
        continuation?.resume(throwing: CancellationError())
    }
}

import Foundation

final class StreamBroadcaster<Element: Sendable>: @unchecked Sendable {
    typealias Continuation = AsyncStream<Element>.Continuation

    private let lock = NSLock()
    private var continuations: [UUID: Continuation] = [:]

    var isEmpty: Bool {
        lock.withLock { continuations.isEmpty }
    }

    func add(_ continuation: Continuation, identifier: UUID) {
        lock.withLock { continuations[identifier] = continuation }
    }

    func remove(identifier: UUID) {
        lock.withLock { continuations[identifier] = nil }
    }

    func yield(_ element: Element) {
        let current = lock.withLock { Array(continuations.values) }
        current.forEach { $0.yield(element) }
    }
}

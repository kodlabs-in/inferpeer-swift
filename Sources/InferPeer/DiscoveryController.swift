import Foundation
import InferPeerCore

actor DiscoveryController {
    private let provider: any ResourceDiscovery
    private var subscribers: [UUID: DiscoveryEventStream.Continuation] = [:]
    private var sourceTask: Task<Void, Never>?

    init(provider: any ResourceDiscovery) {
        self.provider = provider
    }

    func subscribe(options: DiscoveryOptions) async throws -> DiscoveryHandle {
        guard options.eventBufferLimit > 0 else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "The discovery event buffer limit must be greater than zero",
                isRetryable: false
            )
        }
        let identifier = UUID()
        let pair = DiscoveryEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(options.eventBufferLimit)
        )
        subscribers[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(identifier) }
        }
        do {
            try await startSourceIfNeeded(options: options)
        } catch {
            subscribers.removeValue(forKey: identifier)?.finish(throwing: error)
            throw error
        }
        return DiscoveryHandle(events: pair.stream) { [weak self] in
            await self?.unsubscribe(identifier)
        }
    }

    func stop() async {
        let continuations = subscribers.values
        subscribers.removeAll(keepingCapacity: false)
        continuations.forEach { $0.finish() }
        await stopSource()
    }

    private func startSourceIfNeeded(options: DiscoveryOptions) async throws {
        guard sourceTask == nil else { return }
        let stream = try await provider.start(options: options)
        sourceTask = Task { [weak self] in
            do {
                for try await event in stream {
                    await self?.publish(event)
                }
                await self?.sourceFinished(error: nil)
            } catch {
                await self?.sourceFinished(error: error)
            }
        }
    }

    private func publish(_ event: DiscoveryEvent) {
        for continuation in subscribers.values {
            if case .dropped = continuation.yield(event) {
                continuation.finish(
                    throwing: InferPeerError(
                        code: .resourceExhausted,
                        message: "Discovery events exceeded the subscriber buffer",
                        isRetryable: true
                    )
                )
            }
        }
    }

    private func unsubscribe(_ identifier: UUID) async {
        guard let continuation = subscribers.removeValue(forKey: identifier) else { return }
        continuation.finish()
        guard subscribers.isEmpty else { return }
        await stopSource()
    }

    private func sourceFinished(error: (any Error)?) async {
        guard sourceTask != nil else { return }
        sourceTask = nil
        let continuations = subscribers.values
        subscribers.removeAll(keepingCapacity: false)
        for continuation in continuations {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        await provider.stop()
    }

    private func stopSource() async {
        guard let sourceTask else { return }
        self.sourceTask = nil
        sourceTask.cancel()
        await provider.stop()
    }
}

import Foundation
import InferPeerInference
import InferPeerProtocol

extension WorkerSessionService {
    func startResponseLoop(_ session: any WorkerTransportSession) {
        let responses = session.responses(bufferingLimit: configuration.streamBufferLimit)
        responseTask = Task { [weak self] in
            do {
                for try await response in responses {
                    try await self?.receive(response)
                }
            } catch {
                // All stream failures converge on worker shutdown below.
            }
            await self?.stop()
        }
    }

    func startHeartbeatLoop() {
        let interval = configuration.heartbeatInterval
        heartbeatTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    try await self?.sendHeartbeat()
                }
            } catch {
                await self?.stop()
            }
        }
    }

    func startStatusLoop() {
        let updates = statusProvider.updates(bufferingLimit: 1)
        statusTask = Task { [weak self] in
            for await status in updates {
                do {
                    try await self?.apply(status)
                } catch {
                    await self?.stop()
                }
            }
        }
    }

    /// Immediately publishes fresh host state and stops work when participation is unavailable.
    public func refreshStatus() async throws {
        guard isRunning else { return }
        try await apply(await statusProvider.currentStatus())
    }

    func apply(_ status: LocalWorkerStatus) async throws {
        try await sendStatus(status)
        guard status.condition.participation == .unavailable, let active else { return }
        generationTask?.cancel()
        await interruptIfActive(
            active,
            error: InferPeerError(code: .workerUnavailable, isRetryable: true)
        )
    }

    func sendHeartbeat() async throws {
        guard isRunning else { return }
        try await sendStatus()
        guard let active else { return }
        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata(
                requestID: active.requestID,
                attemptID: active.attemptID
            )
            $0.leaseRenewal.requestedDurationMilliseconds =
                configuration.requestedLease.coordinatorWireMilliseconds
        }
        try await enqueue(request)
    }

    func sendStatus() async throws {
        try await sendStatus(await statusProvider.currentStatus())
    }

    func sendStatus(_ status: LocalWorkerStatus) async throws {
        let request = InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata()
            $0.status = status.wireValue
        }
        try await enqueue(request)
    }

    func receive(_ response: InferPeer_V1_WorkerSessionResponse) async throws {
        switch response.payload {
        case .assignment(let assignment):
            try await start(assignment, metadata: response.metadata)
        case .cancelAttempt:
            try await cancel(metadata: response.metadata)
        case .leaseExtended(let lease):
            try await renewLease(lease, metadata: response.metadata)
        default:
            throw CoordinatorError.invalidMessage
        }
    }

}

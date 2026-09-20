import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol

extension DirectResourceHostHandler {
    /// Admits one immutable exact-model request or returns its prior outcome.
    public func startRun(
        _ request: InferPeer_V2_StartRunRequest
    ) async throws -> InferPeer_V2_StartRunResponse {
        let principal = try requirePrincipal()
        guard let requestID = RequestID(rawValue: request.requestID),
            request.remainingTimeoutMilliseconds > 0
        else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let key = RunKey(principalID: principal, requestID: requestID)
        if let existing = runs[key] {
            return try existingResponse(existing, request: request)
        }
        if let pending = pendingRunAdmissions[key] {
            try validatePendingAdmission(pending, request: request)
            return try await pending.task.value
        }
        try enforceRunAdmissionLimits(request)
        let admissionID = UUID()
        let task = Task {
            try await self.admitRun(
                request,
                requestID: requestID,
                principal: principal,
                key: key
            )
        }
        pendingRunAdmissions[key] = PendingRunAdmission(
            id: admissionID,
            specification: request.specificationBytes,
            attachmentReceipts: request.attachmentReceipts,
            originalTimeoutMilliseconds: request.remainingTimeoutMilliseconds,
            task: task
        )
        do {
            let response = try await task.value
            clearPendingAdmission(key, id: admissionID)
            return response
        } catch {
            clearPendingAdmission(key, id: admissionID)
            throw error
        }
    }

    private func admitRun(
        _ request: InferPeer_V2_StartRunRequest,
        requestID: RequestID,
        principal: String,
        key: RunKey
    ) async throws -> InferPeer_V2_StartRunResponse {
        let execution = try await hostedExecution(
            request,
            requestID: requestID,
            principal: principal
        )
        try Task.checkCancellation()
        registerRun(request, execution: execution, key: key)
        try append(.accepted(model: execution.model.key), to: key)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(
                execution.query,
                model: execution.model,
                options: execution.options,
                key: key
            )
        }
        runs[key]?.task = task
        return try response(for: key)
    }

    // Async is required by the service protocol; actor state is already isolated.
    // swiftlint:disable async_without_await
    /// Requests cancellation without overriding an already committed terminal result.
    public func cancelRun(
        _ request: InferPeer_V2_CancelRunRequest
    ) async throws -> InferPeer_V2_CancelRunResponse {
        let principal = try requirePrincipal()
        guard let requestID = RequestID(rawValue: request.requestID) else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        let key = RunKey(principalID: principal, requestID: requestID)
        guard var run = runs[key] else {
            throw InferPeerError(code: .outcomeUnknown, isRetryable: true)
        }
        if !run.status.isHostTerminal {
            run.status = .cancelling
            run.task?.cancel()
            runs[key] = run
        }
        return InferPeer_V2_CancelRunResponse.with {
            $0.state = DirectWireMapper.wireRunState(runs[key]?.status ?? .cancelled)
        }
    }
    // swiftlint:enable async_without_await

    private func execute(
        _ query: InferenceQuery,
        model: InstalledModel,
        options: RunOptions,
        key: RunKey
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.perform(query, model: model, key: key)
                }
                group.addTask {
                    try await Task.sleep(for: options.totalTimeout)
                    throw InferPeerError(code: .deadlineExceeded, isRetryable: false)
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            try? append(.cancelled, to: key)
        } catch let error as InferPeerError where error.code == .deadlineExceeded {
            try? append(.expired, to: key)
        } catch {
            try? append(.failed(Self.publicError(error)), to: key)
        }
    }

    private func perform(
        _ query: InferenceQuery,
        model: InstalledModel,
        key: RunKey
    ) async throws {
        if try await store.status(of: model.key)?.isLoaded != true {
            try append(.loadingModel(model.key), to: key)
            try await store.load(model.key, on: deviceProfile)
        }
        try Task.checkCancellation()
        try append(.started(model: model.key), to: key)
        let stream = try await store.run(query, using: model.key)
        for try await event in stream {
            try Task.checkCancellation()
            for wireEvent in Self.runEvents(event) {
                try append(wireEvent, to: key)
            }
        }
        guard runs[key]?.status.isHostTerminal == true else {
            throw InferPeerError(code: .internal, isRetryable: false)
        }
    }

    private func hostedExecution(
        _ request: InferPeer_V2_StartRunRequest,
        requestID: RequestID,
        principal: String
    ) async throws -> HostedExecution {
        let encoded = EncodedDirectRunSpecification(
            bytes: request.specificationBytes,
            attachmentReceipts: request.attachmentReceipts
        )
        let decoded = try wireCodec.decode(encoded)
        let model = try await selectedModel(for: decoded.query)
        let query = try exactQuery(
            resolveAssets(in: decoded.query, principal: principal),
            model: model.key
        )
        let options = RunOptions(
            requestID: requestID,
            totalTimeout: .milliseconds(request.remainingTimeoutMilliseconds),
            queuePolicy: decoded.options.queuePolicy,
            missingModelPolicy: decoded.options.missingModelPolicy,
            disconnectPolicy: decoded.options.disconnectPolicy
        )
        return HostedExecution(query: query, model: model, options: options)
    }

    private func registerRun(
        _ request: InferPeer_V2_StartRunRequest,
        execution: HostedExecution,
        key: RunKey
    ) {
        runs[key] = HostedRun(
            specification: request.specificationBytes,
            attachmentReceipts: request.attachmentReceipts,
            originalTimeoutMilliseconds: request.remainingTimeoutMilliseconds,
            model: execution.model,
            status: .accepted,
            events: [],
            terminalEvent: nil,
            watchers: [:],
            task: nil,
            completedAt: nil
        )
    }

    func append(_ event: RunEvent, to key: RunKey) throws {
        guard var run = runs[key] else {
            throw InferPeerError(code: .outcomeUnknown, isRetryable: false)
        }
        let nextSequence = (run.events.last?.sequence ?? 0).addingReportingOverflow(1)
        guard !run.status.isHostTerminal, !nextSequence.overflow else {
            throw InferPeerError(code: .internal, isRetryable: false)
        }
        let sequence = nextSequence.partialValue
        let wire = try wireCodec.encode(
            event,
            requestID: key.requestID,
            incarnation: incarnation,
            sequence: sequence
        )
        run.events.append(wire)
        if run.events.count > Self.maximumReplayEvents {
            run.events.removeFirst(run.events.count - Self.maximumReplayEvents)
        }
        run.status = event.hostStatus(current: run.status)
        if event.isHostTerminal {
            run.terminalEvent = wire
            run.completedAt = Date()
        }
        let response = InferPeer_V2_WatchRunResponse.with { $0.event = wire }
        for (id, continuation) in run.watchers {
            if case .dropped = continuation.yield(response) {
                continuation.finish(
                    throwing: InferPeerError(code: .outputBackpressure, isRetryable: false)
                )
                run.watchers[id] = nil
            }
        }
        if event.isHostTerminal {
            run.watchers.values.forEach { $0.finish() }
            run.watchers.removeAll()
        }
        runs[key] = run
    }

    private func enforceRunAdmissionLimits(
        _ request: InferPeer_V2_StartRunRequest
    ) throws {
        guard request.remainingTimeoutMilliseconds <= Self.maximumRunTimeoutMilliseconds else {
            throw InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        removeExpiredRuns()
        let liveKeys = Set(runs.lazy.filter { !$0.value.status.isHostTerminal }.map(\.key))
            .union(pendingRunAdmissions.keys)
        guard liveKeys.count < Self.maximumConcurrentRuns else {
            throw InferPeerError(code: .resourceExhausted, isRetryable: true)
        }
        evictOldestTerminalRunForCapacity()
        let retainedKeys = Set(runs.keys).union(pendingRunAdmissions.keys)
        guard retainedKeys.count < Self.maximumRetainedRuns else {
            throw InferPeerError(code: .resourceExhausted, isRetryable: true)
        }
    }

    private func removeExpiredRuns() {
        let cutoff = Date().addingTimeInterval(-Self.runRetentionInterval)
        runs = runs.filter { _, run in
            guard let completedAt = run.completedAt else { return true }
            return completedAt > cutoff
        }
    }

    private func evictOldestTerminalRunForCapacity() {
        let pendingKeys = Set(pendingRunAdmissions.keys)
        guard Set(runs.keys).union(pendingKeys).count >= Self.maximumRetainedRuns else {
            return
        }
        let oldest = runs
            .filter { $0.value.status.isHostTerminal }
            .min { left, right in
                (left.value.completedAt ?? .distantPast) < (right.value.completedAt ?? .distantPast)
            }?
            .key
        if let oldest { runs[oldest] = nil }
    }

    private func selectedModel(for query: InferenceQuery) async throws -> InstalledModel {
        let models = try await store.installedModels()
        switch query.modelSelection {
        case .exact(let key):
            guard let model = models.first(where: { $0.key == key }),
                model.manifest.capabilities.contains(where: { $0.task == query.task })
            else {
                throw InferPeerError(code: .modelNotInstalled, isRetryable: false)
            }
            return model
        case .taskDefault:
            guard
                let model = models.first(where: {
                    $0.manifest.capabilities.contains(where: { $0.task == query.task })
                })
            else {
                throw InferPeerError(code: .modelNotInstalled, isRetryable: false)
            }
            return model
        }
    }

    private func exactQuery(_ query: InferenceQuery, model: ModelKey) throws -> InferenceQuery {
        switch query {
        case .text(let value):
            .text(
                model: .exact(model),
                messages: value.messages,
                generation: value.generation
            )
        case .vision(let value):
            .vision(
                model: .exact(model),
                messages: value.messages,
                images: value.images,
                generation: value.generation
            )
        case .audioTranscription, .speechSynthesis:
            throw InferPeerError(code: .unsupportedTask, isRetryable: false)
        }
    }

    private func existingResponse(
        _ run: HostedRun,
        request: InferPeer_V2_StartRunRequest
    ) throws -> InferPeer_V2_StartRunResponse {
        guard run.specification == request.specificationBytes,
            run.attachmentReceipts == request.attachmentReceipts,
            request.remainingTimeoutMilliseconds <= run.originalTimeoutMilliseconds
        else {
            throw InferPeerError(code: .requestConflict, isRetryable: false)
        }
        return Self.startResponse(
            run: run,
            requestID: request.requestID,
            incarnation: incarnation
        )
    }

    private func validatePendingAdmission(
        _ admission: PendingRunAdmission,
        request: InferPeer_V2_StartRunRequest
    ) throws {
        guard admission.specification == request.specificationBytes,
            admission.attachmentReceipts == request.attachmentReceipts,
            request.remainingTimeoutMilliseconds <= admission.originalTimeoutMilliseconds
        else {
            throw InferPeerError(code: .requestConflict, isRetryable: false)
        }
    }

    private func clearPendingAdmission(_ key: RunKey, id: UUID) {
        guard pendingRunAdmissions[key]?.id == id else { return }
        pendingRunAdmissions[key] = nil
    }

    private func response(for key: RunKey) throws -> InferPeer_V2_StartRunResponse {
        guard let run = runs[key] else {
            throw InferPeerError(code: .internal, isRetryable: false)
        }
        return Self.startResponse(
            run: run,
            requestID: key.requestID.rawValue,
            incarnation: incarnation
        )
    }

    private static func startResponse(
        run: HostedRun,
        requestID: String,
        incarnation: String
    ) -> InferPeer_V2_StartRunResponse {
        InferPeer_V2_StartRunResponse.with {
            $0.requestID = requestID
            $0.admittedModel = DirectWireMapper.wireModelKey(
                run.model.key,
                runtime: run.model.manifest.runtime.runtimeIdentifier
            )
            $0.runtime = run.model.manifest.runtime.runtimeIdentifier
            $0.state = DirectWireMapper.wireRunState(run.status)
            $0.incarnation = incarnation
            $0.firstEventSequence = run.events.first?.sequence ?? 0
            $0.originalTimeoutMilliseconds = run.originalTimeoutMilliseconds
        }
    }

    private static func runEvents(_ event: DirectRuntimeEvent) -> [RunEvent] {
        switch event {
        case .preprocessing(let stage): [.preprocessing(stage)]
        case .textDelta(let text): [.textDelta(text)]
        case .completed(let result): [.usage(result.usage), .completed(result)]
        case .transcriptSegment(let segment): [.transcriptSegment(segment)]
        case .audioChunk(let chunk): [.audioChunk(chunk)]
        }
    }
}

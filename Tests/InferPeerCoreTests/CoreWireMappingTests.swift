import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Core wire mapping")
struct CoreWireMappingTests {
    @Test("Round-trips every request and cancellation lifecycle state")
    func roundTripsLifecycleStates() throws {
        let requestStates = RequestState.allTestCases
        let cancellationStates = CancellationState.allTestCases

        for state in requestStates {
            #expect(try RequestState(wireValue: state.wireValue) == state)
        }
        for state in cancellationStates {
            #expect(try CancellationState(wireValue: state.wireValue) == state)
        }
    }

    @Test("Rejects unknown lifecycle enum values")
    func rejectsUnknownLifecycleStates() {
        #expect(throws: CoreWireMappingError.invalidRequestState) {
            try RequestState(wireValue: .UNRECOGNIZED(99))
        }
        #expect(throws: CoreWireMappingError.invalidCancellationState) {
            try CancellationState(wireValue: .UNRECOGNIZED(99))
        }
    }

    @Test("Round-trips all host-visible worker status")
    func roundTripsWorkerStatus() throws {
        let status = LocalWorkerStatus(
            condition: WorkerCondition(
                participation: .available,
                thermalState: .fair,
                lowPowerModeEnabled: true
            ),
            load: WorkerLoad(
                activeGenerations: 1,
                generationCapacity: 2,
                availableAppMemoryBytes: 3_000_000_000
            ),
            batteryPercentage: try BatteryPercentage(72),
            models: [
                try WorkerModelSnapshot(
                    model: makeModelReference(),
                    isLoaded: true,
                    measuredMemoryBytes: 2_000_000_000,
                    estimatedLoadDuration: .milliseconds(750)
                )
            ]
        )

        #expect(try LocalWorkerStatus(wireValue: status.wireValue) == status)
    }

    @Test("Rejects invalid worker status")
    func rejectsInvalidWorkerStatus() {
        let invalidBattery = InferPeer_V1_WorkerStatus.with {
            $0.participation = .available
            $0.thermalState = .nominal
            $0.batteryPercent = 101
        }
        let missingModel = InferPeer_V1_WorkerStatus.with {
            $0.participation = .available
            $0.thermalState = .nominal
            $0.models = [InferPeer_V1_ModelStatus()]
        }

        #expect(
            throws: PeerServiceValidationError.invalidBatteryPercentage(actual: 101)
        ) {
            try LocalWorkerStatus(wireValue: invalidBattery)
        }
        #expect(throws: CoreWireMappingError.missingModelReference) {
            try LocalWorkerStatus(wireValue: missingModel)
        }
    }

    private func makeModelReference() throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: "model-1"))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }
}

private extension RequestState {
    static let allTestCases: [Self] = [
        .queued, .assigned, .running, .completed, .failed, .cancelled, .expired,
    ]
}

private extension CancellationState {
    static let allTestCases: [Self] = [.notRequested, .pending, .confirmed, .tooLate]
}

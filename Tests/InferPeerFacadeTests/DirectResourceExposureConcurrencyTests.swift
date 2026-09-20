@testable import InferPeer
import InferPeerCore
import Testing

@Suite("Direct-resource exposure concurrency")
struct DirectResourceExposureConcurrencyTests {
    @Test("Concurrent exposure requests share one in-flight start")
    func concurrentExposureStartsAreCoalesced() async throws {
        let exposure = DirectFakeExposure(startDelay: .milliseconds(10))
        let fixture = try DirectResourceFixture(exposure: exposure)
        let facade = fixture.facade

        let handles = try await withThrowingTaskGroup(of: ExposureHandle.self) { group in
            for _ in 0..<4 {
                group.addTask { try await facade.expose() }
            }
            var values: [ExposureHandle] = []
            for try await handle in group { values.append(handle) }
            return values
        }

        #expect(handles.count == 4)
        #expect(await exposure.startCount() == 1)
        await fixture.facade.stop()
        #expect(await exposure.stopCount() == 1)
    }

    @Test("Stopping during exposure startup prevents a late active listener")
    func stopCancelsInFlightExposureStart() async throws {
        let exposure = DirectFakeExposure(startDelay: .seconds(30))
        let fixture = try DirectResourceFixture(exposure: exposure)
        let facade = fixture.facade
        let start = Task { try await facade.expose() }
        while await exposure.startCount() == 0 { await Task.yield() }

        await facade.stop()

        await #expect(throws: (any Error).self) {
            _ = try await start.value
        }
        #expect(await exposure.startCount() == 1)
        #expect(await exposure.stopCount() == 0)
    }

    @Test("Concurrent stops share one teardown")
    func concurrentStopsAreCoalesced() async throws {
        let exposure = DirectFakeExposure()
        let fixture = try DirectResourceFixture(exposure: exposure)
        _ = try await fixture.facade.expose()

        async let first: Void = fixture.facade.stop()
        async let second: Void = fixture.facade.stop()
        _ = await (first, second)

        #expect(await exposure.stopCount() == 1)
    }
}

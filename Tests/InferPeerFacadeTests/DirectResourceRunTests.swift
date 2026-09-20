import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

extension DirectResourceFacadeTests {
    @Test("Local run streams ordered events and resolves one independent result")
    func localRunUsesTheInProcessBackend() async throws {
        let fixture = try DirectResourceFixture()
        let handle = try await fixture.facade.run(
            fixture.query(),
            resourceId: .local
        )

        let result = try await handle.result()
        var eventKinds: [String] = []
        for try await event in handle.events {
            eventKinds.append(event.kind)
        }

        #expect(result.text == DirectFakeBackend.output)
        #expect(result.model == fixture.model.descriptor.reference)
        #expect(
            eventKinds == [
                "accepted", "loadingModel", "started", "textDelta", "usage", "completed",
            ]
        )
        #expect(await fixture.backend.loadedModels() == [fixture.model.descriptor.reference])
        #expect(await handle.status() == .completed)
    }

    @Test("A nonlocal destination never falls back to the local backend")
    func unavailableRemoteDoesNotReroute() async throws {
        let fixture = try DirectResourceFixture()

        await #expect(throws: InferPeerError.self) {
            _ = try await fixture.facade.run(
                fixture.query(),
                resourceId: ResourceID(rawValue: "remote-resource")
            )
        }
        #expect(await fixture.backend.generationCount() == 0)
    }

    @Test("A remote run uses only the selected authenticated session")
    func remoteRunUsesTheSelectedSession() async throws {
        let sessions = DirectFakeSessionManager()
        let fixture = try DirectResourceFixture(sessionManager: sessions)
        let invitation = try Self.remoteInvitation()
        _ = try await fixture.facade.pair(invitation)

        let handle = try await fixture.facade.run(
            fixture.query(),
            resourceId: invitation.resourceID
        )
        let result = try await handle.result()

        #expect(handle.resourceID == invitation.resourceID)
        #expect(result.text == DirectFakeSessionManager.output)
        #expect(await sessions.runResources() == [invitation.resourceID])
        #expect(await fixture.backend.generationCount() == 0)
    }

    @Test("An unsupported modality fails before the text runtime is invoked")
    func unsupportedLocalTaskFailsHonestly() async throws {
        let fixture = try DirectResourceFixture()
        let query = InferenceQuery.vision(
            model: .exact(fixture.model.descriptor.reference),
            messages: [.user("Describe this image")],
            images: [.file(URL(fileURLWithPath: "/tmp/input.jpg"))]
        )

        do {
            _ = try await fixture.facade.run(query, resourceId: .local)
            Issue.record("A text-only resource accepted a vision request")
        } catch let error as InferPeerError {
            #expect(error.code == .unsupportedTask)
        }
        #expect(await fixture.backend.generationCount() == 0)
    }

    @Test("A second local run waits in the bounded resource queue")
    func localQueueSerializesHeavyInference() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let first = try await fixture.facade.run(fixture.query(), resourceId: .local)
        await fixture.backend.waitUntilGenerationStarts(count: 1)
        let second = try await fixture.facade.run(fixture.query(), resourceId: .local)
        var secondEvents = second.events.makeAsyncIterator()

        guard case .accepted? = try await secondEvents.next() else {
            Issue.record("Second run did not emit acceptance")
            return
        }
        guard case .queued(position: 1)? = try await secondEvents.next() else {
            Issue.record("Second run did not enter the bounded queue")
            return
        }
        #expect(await second.status() == .queued(position: 1))

        await fixture.backend.completeAll()
        _ = try await first.result()
        await fixture.backend.waitUntilGenerationStarts(count: 2)
        await fixture.backend.completeAll()
        _ = try await second.result()
        #expect(await fixture.backend.maximumConcurrentGenerations() == 1)
    }

    @Test("Queue saturation returns the stable queue-full error")
    func queueSaturationIsTyped() async throws {
        let fixture = try DirectResourceFixture(
            autoComplete: false,
            maximumPendingLocalRuns: 1
        )
        _ = try await fixture.facade.run(fixture.query(), resourceId: .local)
        await fixture.backend.waitUntilGenerationStarts(count: 1)
        let queued = try await fixture.facade.run(fixture.query(), resourceId: .local)
        var queuedEvents = queued.events.makeAsyncIterator()
        _ = try await queuedEvents.next()
        _ = try await queuedEvents.next()
        let rejected = try await fixture.facade.run(fixture.query(), resourceId: .local)

        do {
            _ = try await rejected.result()
            Issue.record("A run beyond the bounded queue unexpectedly completed")
        } catch let error as InferPeerError {
            #expect(error.code == .queueFull)
        }
        await fixture.facade.stop()
    }

    @Test("Retrying one immutable request ID executes only once")
    func duplicateRequestIDReturnsTheOriginalRun() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let requestID = try #require(RequestID(rawValue: "deduplicated-request"))
        let options = RunOptions(requestID: requestID)

        let original = try await fixture.facade.run(
            fixture.query(),
            resourceId: .local,
            options: options
        )
        let retry = try await fixture.facade.run(
            fixture.query(),
            resourceId: .local,
            options: options
        )
        await fixture.backend.waitUntilGenerationStarts(count: 1)
        await fixture.backend.completeAll()

        let originalResult = try await original.result()
        let retryResult = try await retry.result()
        #expect(originalResult == retryResult)
        #expect(await fixture.backend.generationCount() == 1)
    }

    @Test("Concurrent retries of one request ID share a single admission")
    func concurrentDuplicateRequestIDsShareAdmission() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let requestID = try #require(RequestID(rawValue: "concurrent-deduplicated-request"))
        let options = RunOptions(requestID: requestID)
        let facade = fixture.facade
        let query = fixture.query()

        let handles = try await withThrowingTaskGroup(of: RunHandle.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await facade.run(query, resourceId: .local, options: options)
                }
            }
            var values: [RunHandle] = []
            for try await handle in group { values.append(handle) }
            return values
        }
        await fixture.backend.waitUntilGenerationStarts(count: 1)
        await fixture.backend.completeAll()
        let results = try await withThrowingTaskGroup(of: RunResult.self) { group in
            for handle in handles {
                group.addTask { try await handle.result() }
            }
            var values: [RunResult] = []
            for try await result in group { values.append(result) }
            return values
        }

        #expect(Set(results).count == 1)
        #expect(await fixture.backend.generationCount() == 1)
    }

    @Test("Reusing a request ID for different content is rejected")
    func conflictingRequestIDIsRejected() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let requestID = try #require(RequestID(rawValue: "conflicting-request"))
        let options = RunOptions(requestID: requestID)
        _ = try await fixture.facade.run(
            fixture.query(text: "First immutable request"),
            resourceId: .local,
            options: options
        )

        do {
            _ = try await fixture.facade.run(
                fixture.query(text: "Different immutable request"),
                resourceId: .local,
                options: options
            )
            Issue.record("Conflicting content reused a request ID")
        } catch let error as InferPeerError {
            #expect(error.code == .requestConflict)
        }
    }

    @Test("Cancellation reaches the selected local runtime")
    func cancellationIsCooperative() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let handle = try await fixture.facade.run(fixture.query(), resourceId: .local)
        await fixture.backend.waitUntilGenerationStarts(count: 1)

        await handle.cancel()

        await #expect(throws: InferPeerError.self) {
            _ = try await handle.result()
        }
        #expect(await fixture.backend.cancelCount() == 1)
        #expect(await handle.status() == .cancelled)
    }

    @Test("The total timeout cancels work and reports deadline exceeded")
    func timeoutIsEnforcedOnTheSelectedRuntime() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let handle = try await fixture.facade.run(
            fixture.query(),
            resourceId: .local,
            options: RunOptions(totalTimeout: .milliseconds(10))
        )

        do {
            _ = try await handle.result()
            Issue.record("A held run unexpectedly completed")
        } catch let error as InferPeerError {
            #expect(error.code == .deadlineExceeded)
        }
        #expect(await fixture.backend.cancelCount() == 1)
        #expect(await handle.status() == .expired)

        var terminalWasExpired = false
        for try await event in handle.events {
            if case .expired = event {
                terminalWasExpired = true
            }
        }
        #expect(terminalWasExpired)
    }

    @Test("A slow event consumer stops generation with explicit output backpressure")
    func outputBackpressureIsTyped() async throws {
        let fixture = try DirectResourceFixture(runEventBufferLimit: 1)
        let handle = try await fixture.facade.run(fixture.query(), resourceId: .local)

        do {
            _ = try await handle.result()
            Issue.record("A run with an exhausted event buffer unexpectedly completed")
        } catch let error as InferPeerError {
            #expect(error.code == .outputBackpressure)
        }
    }

    @Test("Stopping during a run cancels first and unloads after the runtime is safe")
    func stopDuringRunReleasesTheLoadedModel() async throws {
        let fixture = try DirectResourceFixture(autoComplete: false)
        let handle = try await fixture.facade.run(fixture.query(), resourceId: .local)
        await fixture.backend.waitUntilGenerationStarts(count: 1)

        await fixture.facade.stop()
        await #expect(throws: InferPeerError.self) {
            _ = try await handle.result()
        }

        #expect(await fixture.backend.cancelCount() == 1)
        #expect(await fixture.backend.unloadedModels() == [fixture.model.descriptor.reference])
    }

    private static func remoteInvitation() throws -> ResourcePairingInvitation {
        try ResourcePairingInvitation(
            protocolMajor: 2,
            resourceID: ResourceID(rawValue: "remote-resource"),
            endpoint: PeerEndpoint(host: "192.168.1.25", port: 8443),
            certificateFingerprint: CertificateFingerprint(
                bytes: Data(repeating: 0xC4, count: CertificateFingerprint.byteCount)
            ),
            secret: Data(repeating: 0xD5, count: ResourcePairingInvitation.secretByteCount),
            expiresAt: Date().addingTimeInterval(120)
        )
    }
}

import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerGRPC
import InferPeerModelStore
import InferPeerProtocol
import Testing

@Suite("Direct resource host security boundaries")
struct DirectResourceHostSecurityTests {
    @Test("Host startup removes crash-orphaned ephemeral assets")
    func removesOrphanedAssetsAtStartup() async throws {
        let fixture = try await DirectHostFixture(seedOrphanAsset: true)
        defer { fixture.remove() }
        let assetRoot = fixture.modelFixture.root.appendingPathComponent(
            "assets",
            isDirectory: true
        )

        #expect(try FileManager.default.contentsOfDirectory(atPath: assetRoot.path).isEmpty)
    }

    @Test("Uploaded image bytes must match their declared format")
    func rejectsMismatchedImageBytes() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }

        await #expect(throws: InferPeerError.self) {
            _ = try await uploadAsset(Data("not-a-jpeg".utf8), handler: fixture.handler)
        }
    }

    @Test("Concurrent identical starts coalesce into one admitted execution")
    func coalescesConcurrentIdenticalStarts() async throws {
        let probe = AdapterProbe()
        let fixture = try await DirectHostFixture(
            runtimeAdapter: TestRuntimeAdapter(probe: probe)
        )
        defer { fixture.remove() }
        let request = try textRunRequest(
            model: fixture.installed.key,
            requestID: "host-run-concurrent"
        )
        let handler = fixture.handler

        let responses = try await withThrowingTaskGroup(
            of: InferPeer_V2_StartRunResponse.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await withPrincipal("owner-one") {
                        try await handler.startRun(request)
                    }
                }
            }
            var values: [InferPeer_V2_StartRunResponse] = []
            for try await response in group { values.append(response) }
            return values
        }
        _ = try await completedRun(
            handler: fixture.handler,
            requestID: try #require(RequestID(rawValue: request.requestID)),
            principal: "owner-one"
        )

        #expect(responses.count == 8)
        #expect(Set(responses.map(\.requestID)) == [request.requestID])
        #expect(await probe.loadCount == 1)
    }

    @Test("A maximum replay cursor is rejected without integer overflow")
    func rejectsOverflowingReplayCursor() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let request = try textRunRequest(
            model: fixture.installed.key,
            requestID: "host-run-cursor"
        )
        _ = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        let watch = DirectRPCStream<InferPeer_V2_WatchRunRequest>.makeStream()
        watch.continuation.yield(watchRequest(requestID: request.requestID, cursor: .max))

        do {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.watchRun(watch.stream)
            }
            Issue.record("Expected an invalid replay cursor")
        } catch let error as InferPeerError {
            #expect(error.code == .invalidRequest)
        }
        watch.continuation.finish()
    }

    @Test("Run timeouts are bounded before host admission")
    func rejectsUnboundedRunTimeout() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        var request = try textRunRequest(
            model: fixture.installed.key,
            requestID: "host-run-timeout-limit"
        )
        request.remainingTimeoutMilliseconds =
            DirectResourceHostHandler.maximumRunTimeoutMilliseconds + 1

        do {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.startRun(request)
            }
            Issue.record("Expected an excessive timeout to be rejected")
        } catch let error as InferPeerError {
            #expect(error.code == .invalidRequest)
        }
    }

    @Test("A runtime stream that ends without a terminal event fails the run")
    func failsRunWhenRuntimeOmitsTerminalEvent() async throws {
        let fixture = try await DirectHostFixture(runtimeAdapter: EmptyRuntimeAdapter())
        defer { fixture.remove() }
        let request = try textRunRequest(
            model: fixture.installed.key,
            requestID: "host-run-no-terminal"
        )
        _ = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }

        let terminal = try await terminalRun(
            handler: fixture.handler,
            requestID: try #require(RequestID(rawValue: request.requestID)),
            principal: "owner-one"
        )

        #expect(terminal.state == .failed)
        #expect(terminal.hasTerminalEvent)
    }

    @Test("Suspending exposure interrupts work and rotates process-local state")
    func suspendInterruptsAndClearsRuns() async throws {
        let fixture = try await DirectHostFixture(runtimeAdapter: HangingRuntimeAdapter())
        defer { fixture.remove() }
        let request = try textRunRequest(
            model: fixture.installed.key,
            requestID: "host-run-suspend"
        )
        let before = try await withPrincipal("owner-one") {
            try await fixture.handler.hello(helloRequest())
        }
        _ = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        let watch = DirectRPCStream<InferPeer_V2_WatchRunRequest>.makeStream()
        watch.continuation.yield(watchRequest(requestID: request.requestID, cursor: 0))
        let events = try await withPrincipal("owner-one") {
            try await fixture.handler.watchRun(watch.stream)
        }

        await fixture.handler.suspend()

        let terminal = try await terminalEvent(in: events)
        let after = try await withPrincipal("owner-one") {
            try await fixture.handler.hello(helloRequest())
        }
        #expect(before.incarnation != after.incarnation)
        guard case .interrupted? = terminal else {
            Issue.record("Expected an interrupted terminal event")
            return
        }
        await expectUnknownRun(fixture.handler, requestID: request.requestID)
        watch.continuation.finish()
    }

    @Test("Asset declarations are admitted atomically within an owner quota")
    func enforcesAssetDeclarationQuotaAtomically() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let oversized = InferPeer_V2_PrepareAssetsRequest.with { request in
            request.assets = (0..<5).map(largeAssetDeclaration)
        }

        do {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.prepareAssets(oversized)
            }
            Issue.record("Expected the per-owner asset quota to reject the batch")
        } catch let error as InferPeerError {
            #expect(error.code == .resourceExhausted)
        }
        let admitted = try await withPrincipal("owner-one") {
            try await fixture.handler.prepareAssets(singleByteAssetRequest())
        }
        #expect(admitted.tickets.count == 1)
    }

    @Test("Tiny asset declarations cannot bypass object-count quotas")
    func enforcesAssetObjectQuota() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        for batch in 0..<(DirectResourceHostHandler.maximumPrincipalAssetObjects / 8) {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.prepareAssets(tinyAssetRequest(batch: batch))
            }
        }

        await #expect(throws: InferPeerError.self) {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.prepareAssets(singleByteAssetRequest())
            }
        }
        await fixture.handler.suspend()
    }

    @Test("Resource snapshot watchers are capped per principal")
    func capsResourceWatchers() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        var streams: [DirectRPCStream<InferPeer_V2_WatchResourceResponse>] = []
        for _ in 0..<DirectResourceHostHandler.maximumResourceWatchersPerPrincipal {
            let stream = try await withPrincipal("owner-one") {
                try await fixture.handler.watchResource(.init())
            }
            streams.append(stream)
        }

        await #expect(throws: InferPeerError.self) {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.watchResource(.init())
            }
        }
        #expect(streams.count == DirectResourceHostHandler.maximumResourceWatchersPerPrincipal)
        await fixture.handler.suspend()
    }
}

private func watchRequest(
    requestID: String,
    cursor: UInt64
) -> InferPeer_V2_WatchRunRequest {
    InferPeer_V2_WatchRunRequest.with {
        $0.requestID = requestID
        $0.resumeAfterSequence = cursor
    }
}

private func terminalEvent(
    in events: DirectRPCStream<InferPeer_V2_WatchRunResponse>
) async throws -> RunEvent? {
    var iterator = events.makeAsyncIterator()
    var terminal: RunEvent?
    while let response = try await iterator.next() {
        guard response.hasEvent else { continue }
        let event = try DefaultDirectResourceWireCodec().decode(response.event)
        if event.isTestTerminal { terminal = event }
    }
    return terminal
}

private func expectUnknownRun(
    _ handler: DirectResourceHostHandler,
    requestID: String
) async {
    await #expect(throws: InferPeerError.self) {
        _ = try await withPrincipal("owner-one") {
            try await handler.getRun(
                InferPeer_V2_GetRunRequest.with { $0.requestID = requestID }
            )
        }
    }
}

private func largeAssetDeclaration(index: Int) -> InferPeer_V2_AssetDeclaration {
    InferPeer_V2_AssetDeclaration.with {
        $0.clientAssetID = "image-\(index)"
        $0.byteCount = DirectResourceHostHandler.maximumAssetBytes
        $0.sha256 = Data(repeating: UInt8(index), count: 32)
        $0.mediaType = "image/jpeg"
    }
}

private func singleByteAssetRequest() -> InferPeer_V2_PrepareAssetsRequest {
    InferPeer_V2_PrepareAssetsRequest.with {
        $0.assets = [
            InferPeer_V2_AssetDeclaration.with {
                $0.clientAssetID = "small-image"
                $0.byteCount = 1
                $0.sha256 = Data(repeating: 1, count: 32)
                $0.mediaType = "image/jpeg"
            }
        ]
    }
}

private func tinyAssetRequest(batch: Int) -> InferPeer_V2_PrepareAssetsRequest {
    InferPeer_V2_PrepareAssetsRequest.with { request in
        request.assets = (0..<8).map { index in
            InferPeer_V2_AssetDeclaration.with {
                $0.clientAssetID = "tiny-\(batch)-\(index)"
                $0.byteCount = 1
                $0.sha256 = Data(repeating: UInt8(batch), count: 32)
                $0.mediaType = "image/jpeg"
            }
        }
    }
}

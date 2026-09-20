import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Foreground direct resource host")
struct DirectResourceHostHandlerTests {
    @Test("Pairing authorizes hello and advertises only installed text and vision models")
    func pairingAndHello() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let invitation = try await fixture.invitations.issue(
            resourceID: fixture.resourceID,
            endpoint: try PeerEndpoint(host: "192.168.1.40", port: 9_443),
            certificateFingerprint: CertificateFingerprint(bytes: Data(repeating: 3, count: 32))
        )
        let response = try await fixture.handler.pair(
            InferPeer_V2_PairRequest.with {
                $0.protocolMajor = 2
                $0.invitationID = invitation.invitationID?.rawValue ?? ""
                $0.expectedResourceID = fixture.resourceID.rawValue
                $0.invitationSecret = invitation.secret
            }
        )
        let principal = try await fixture.access.authorize(response.credential)

        let hello = try await withPrincipal(principal.rawValue) {
            try await fixture.handler.hello(helloRequest())
        }

        #expect(hello.resourceID == fixture.resourceID.rawValue)
        #expect(hello.supportedTasks == [.text])
        #expect(!hello.optionalFeatures.contains("audio"))
    }

    @Test("A text run executes once and replays its terminal outcome")
    func runsAndReplaysText() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let codec = DefaultDirectResourceWireCodec()
        let requestID = try #require(RequestID(rawValue: "host-run-1"))
        let request = try textRunRequest(
            model: fixture.installed.key,
            requestID: requestID.rawValue
        )

        let first = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        let terminal = try await completedRun(
            handler: fixture.handler,
            requestID: requestID,
            principal: "owner-one"
        )
        let replay = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        let event = try codec.decode(terminal.terminalEvent)

        #expect(first.requestID == requestID.rawValue)
        #expect(replay.requestID == first.requestID)
        #expect(replay.state == .completed)
        guard case .completed(let result) = event else {
            Issue.record("Expected a completed terminal event")
            return
        }
        #expect(result.text == "offline")
    }

    @Test("A replay cannot extend the originally admitted timeout")
    func replayCannotExtendTimeout() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let request = try textRunRequest(
            model: fixture.installed.key,
            requestID: "host-run-timeout",
            timeoutMilliseconds: 5_000
        )
        _ = try await withPrincipal("owner-one") {
            try await fixture.handler.startRun(request)
        }
        var extended = request
        extended.remainingTimeoutMilliseconds = 5_001

        do {
            _ = try await withPrincipal("owner-one") {
                try await fixture.handler.startRun(extended)
            }
            Issue.record("Expected a conflicting timeout extension")
        } catch let error as InferPeerError {
            #expect(error.code == .requestConflict)
        }
    }

    @Test("Uploaded image receipts are isolated to their paired owner")
    func isolatesUploadedAssets() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let receipt = try await uploadAsset(bytes, handler: fixture.handler)

        await #expect(throws: InferPeerError.self) {
            _ = try await withPrincipal("owner-two") {
                try await fixture.handler.releaseAsset(
                    InferPeer_V2_ReleaseAssetRequest.with { $0.receipt = receipt.receipt }
                )
            }
        }
        let released = try await withPrincipal("owner-one") {
            try await fixture.handler.releaseAsset(
                InferPeer_V2_ReleaseAssetRequest.with { $0.receipt = receipt.receipt }
            )
        }
        #expect(released.released)
    }

    @Test("Resource watches stay live and publish bounded heartbeats")
    func resourceWatchHeartbeats() async throws {
        let fixture = try await DirectHostFixture()
        defer { fixture.remove() }
        let stream = try await withPrincipal("owner-one") {
            try await fixture.handler.watchResource(
                InferPeer_V2_WatchResourceRequest.with { $0.knownRevision = 0 }
            )
        }
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(try await iterator.next())
        let heartbeat = try #require(try await iterator.next())

        guard case .snapshot? = snapshot.payload else {
            Issue.record("Expected the initial resource snapshot")
            return
        }
        guard case .heartbeatRevision(let revision)? = heartbeat.payload else {
            Issue.record("Expected a resource heartbeat")
            return
        }
        #expect(revision == 1)
    }
}

import Foundation
import InferPeerCore
@testable import InferPeerDiscovery
import Testing

@Suite("Direct-resource Bonjour discovery")
struct BonjourResourceDiscoveryTests {
    @Test("Valid v2 records produce stable ephemeral candidates and removal events")
    func candidateLifecycle() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        let stream = try await discovery.start(options: .default)
        var iterator = stream.makeAsyncIterator()
        let key = observationKey(interfaceIndex: 4)

        await source.send(.upsert(try observation(key: key, host: "192.168.1.20")))
        let firstEvent = try #require(try await iterator.next())
        let first = try #require(firstEvent.candidate)
        await source.send(.upsert(try observation(key: key, host: "192.168.1.21")))
        let updatedEvent = try #require(try await iterator.next())
        let updated = try #require(updatedEvent.candidate)
        await source.send(.removed(key))
        let removedEvent = try #require(try await iterator.next())
        let removedID = try #require(removedEvent.removedID)

        #expect(first.id == updated.id)
        #expect(first.id == CandidateID(rawValue: "candidate-1"))
        #expect(updated.endpoint.host == "192.168.1.21")
        #expect(updated.protocolMajor == 2)
        #expect(updated.installationHint == Data(repeating: 0xA5, count: 16))
        #expect(updated.capabilityVersion == 7)
        #expect(removedID == first.id)
        await discovery.stop()
    }

    @Test("Service instance interfaces remain distinct candidates")
    func interfaceScopedCandidates() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        let stream = try await discovery.start(options: .default)
        var iterator = stream.makeAsyncIterator()
        let firstKey = observationKey(interfaceIndex: 4)
        let secondKey = observationKey(interfaceIndex: 7)

        await source.send(.upsert(try observation(key: firstKey)))
        await source.send(.upsert(try observation(key: secondKey)))
        let firstEvent = try #require(try await iterator.next())
        let secondEvent = try #require(try await iterator.next())
        let first = try #require(firstEvent.candidate)
        let second = try #require(secondEvent.candidate)

        #expect(first.id != second.id)
        #expect(first.id.rawValue == "candidate-1")
        #expect(second.id.rawValue == "candidate-2")
        await discovery.stop()
    }

    @Test("Invalid endpoint updates withdraw an existing candidate")
    func rejectsNonLocalEndpoint() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        let stream = try await discovery.start(options: .default)
        var iterator = stream.makeAsyncIterator()
        let key = observationKey(interfaceIndex: 4)

        await source.send(.upsert(try observation(key: key)))
        let foundEvent = try #require(try await iterator.next())
        let candidate = try #require(foundEvent.candidate)
        await source.send(.upsert(try observation(key: key, host: "8.8.8.8")))
        let removedEvent = try #require(try await iterator.next())
        let removedID = try #require(removedEvent.removedID)

        #expect(removedID == candidate.id)
        await discovery.stop()
    }

    @Test("Malformed TXT updates withdraw an existing candidate")
    func rejectsMalformedTXTUpdate() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        let stream = try await discovery.start(options: .default)
        var iterator = stream.makeAsyncIterator()
        let key = observationKey(interfaceIndex: 4)

        await source.send(.upsert(try observation(key: key)))
        let foundEvent = try #require(try await iterator.next())
        let candidate = try #require(foundEvent.candidate)
        var incompatibleRecord = validTXTRecord()
        incompatibleRecord["v"] = Data("1".utf8)
        await source.send(
            .upsert(try observation(key: key, txtRecord: incompatibleRecord))
        )
        let removedEvent = try #require(try await iterator.next())

        #expect(removedEvent.removedID == candidate.id)
        await discovery.stop()
    }

    @Test("Browser permission and availability events are forwarded")
    func forwardsBrowserState() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        let stream = try await discovery.start(options: .default)
        var iterator = stream.makeAsyncIterator()

        await source.send(.permissionRequired)
        await source.send(.permissionDenied)
        await source.send(.discoveryUnavailable)

        #expect(try await iterator.next()?.kind == .permissionRequired)
        #expect(try await iterator.next()?.kind == .permissionDenied)
        #expect(try await iterator.next()?.kind == .discoveryUnavailable)
        await discovery.stop()
    }

    @Test("Stop is idempotent and releases the browser exactly once")
    func stopLifecycle() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        let stream = try await discovery.start(options: .default)
        var iterator = stream.makeAsyncIterator()

        await discovery.stop()
        await discovery.stop()

        #expect(await source.stopCount == 1)
        #expect(try await iterator.next() == nil)
    }

    @Test("An active browser rejects a second start and can restart after stop")
    func exclusiveRestartableLifecycle() async throws {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)
        _ = try await discovery.start(options: .default)

        await #expect(throws: PeerDiscoveryError.discoveryAlreadyActive) {
            _ = try await discovery.start(options: .default)
        }
        await discovery.stop()
        _ = try await discovery.start(options: .default)
        await discovery.stop()

        #expect(await source.startCount == 2)
        #expect(await source.stopCount == 2)
    }

    @Test("Direct discovery requires a positive event buffer")
    func rejectsInvalidBuffer() async {
        let source = TestBonjourBrowseSource()
        let discovery = makeDiscovery(source: source)

        await #expect(throws: PeerDiscoveryError.invalidBufferingLimit) {
            _ = try await discovery.start(options: .init(eventBufferLimit: 0))
        }
        #expect(await source.startCount == 0)
    }

    private func makeDiscovery(source: TestBonjourBrowseSource) -> BonjourResourceDiscovery {
        let sequence = CandidateSequence()
        return BonjourResourceDiscovery(
            configuration: .init(permitsLoopback: true),
            source: source,
            makeCandidateID: { sequence.next() }
        )
    }

    private func observationKey(interfaceIndex: Int) -> BonjourObservationKey {
        BonjourObservationKey(
            serviceName: "Resource",
            domain: "local.",
            interfaceIndex: interfaceIndex
        )
    }

    private func observation(
        key: BonjourObservationKey,
        host: String = "192.168.1.10",
        txtRecord: [String: Data]? = nil
    ) throws -> BonjourServiceObservation {
        BonjourServiceObservation(
            key: key,
            serviceName: key.serviceName,
            serviceType: BonjourDiscoveryConfiguration.serviceType,
            endpoint: try PeerEndpoint(host: host, port: 9443),
            txtRecord: txtRecord ?? validTXTRecord()
        )
    }

    private func validTXTRecord() -> [String: Data] {
        [
            "v": Data("2".utf8),
            "i": Data(repeating: 0xA5, count: 16),
            "c": Data("7".utf8),
        ]
    }
}

@Suite("Direct-resource Bonjour metadata")
struct DirectBonjourMetadataTests {
    @Test("TXT validation rejects missing, unknown, incompatible, and oversized values")
    func rejectsInvalidRecords() {
        let valid: [String: Data] = [
            "v": Data("2".utf8),
            "i": Data(repeating: 1, count: 16),
            "c": Data("1".utf8),
        ]
        var records = [[String: Data]]()
        records.append(["v": Data("2".utf8)])
        records.append(valid.merging(["extra": Data()]) { first, _ in first })
        records.append(valid.merging(["v": Data("1".utf8)]) { _, second in second })
        records.append(
            valid.merging(["i": Data(repeating: 1, count: 65)]) { _, second in second }
        )
        records.append(valid.merging(["c": Data("-1".utf8)]) { _, second in second })

        for record in records {
            #expect(throws: PeerDiscoveryError.invalidTXTRecord) {
                _ = try DirectBonjourTXTRecord(dictionary: record)
            }
        }
    }

    @Test("Direct advertisement publishes only the three bounded v2 hints")
    @MainActor
    func publishesDirectMetadata() throws {
        var publishedService: NetService?
        let advertiser = try BonjourServiceAdvertiser(
            serviceName: "Resource",
            port: 9443,
            publishService: { publishedService = $0 },
            stopService: { _ in }
        )
        let metadata = try DirectBonjourAdvertisementMetadata(
            installationHint: Data(repeating: 0x5A, count: 16),
            capabilityVersion: 9
        )

        try advertiser.startDirect(metadata: metadata)
        defer { advertiser.stop() }
        let service = try #require(publishedService)
        let data = try #require(service.txtRecordData())
        let dictionary = NetService.dictionary(fromTXTRecord: data)

        #expect(Set(dictionary.keys) == Set(["v", "i", "c"]))
        #expect(dictionary["v"] == Data("2".utf8))
        #expect(dictionary["i"] == metadata.installationHint)
        #expect(dictionary["c"] == Data("9".utf8))
    }

    @Test("Direct advertisement rejects empty and oversized installation hints")
    func rejectsInvalidInstallationHints() {
        #expect(throws: PeerDiscoveryError.invalidTXTRecord) {
            _ = try DirectBonjourAdvertisementMetadata(
                installationHint: Data(),
                capabilityVersion: 1
            )
        }
        #expect(throws: PeerDiscoveryError.invalidTXTRecord) {
            _ = try DirectBonjourAdvertisementMetadata(
                installationHint: Data(repeating: 0, count: 65),
                capabilityVersion: 1
            )
        }
    }
}

private final class CandidateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> CandidateID {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return CandidateID(rawValue: "candidate-\(value)")
    }
}

private actor TestBonjourBrowseSource: BonjourResourceBrowseSource {
    private var continuation: BonjourBrowseEventStream.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(bufferingLimit: Int) throws -> BonjourBrowseEventStream {
        startCount += 1
        let pair = BonjourBrowseEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        guard continuation != nil else { return }
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func send(_ event: BonjourBrowseEvent) {
        continuation?.yield(event)
    }
}

private enum DiscoveryEventKind: Equatable {
    case candidateFound
    case candidateRemoved
    case permissionRequired
    case permissionDenied
    case discoveryUnavailable
}

private extension DiscoveryEvent {
    var candidate: DiscoveryCandidate? {
        guard case .candidateFound(let candidate) = self else { return nil }
        return candidate
    }

    var removedID: CandidateID? {
        guard case .candidateRemoved(let candidateID) = self else { return nil }
        return candidateID
    }

    var kind: DiscoveryEventKind {
        switch self {
        case .candidateFound: .candidateFound
        case .candidateRemoved: .candidateRemoved
        case .permissionRequired: .permissionRequired
        case .permissionDenied: .permissionDenied
        case .discoveryUnavailable: .discoveryUnavailable
        }
    }
}

import Foundation
import InferPeerCore
@testable import InferPeerDiscovery
import Testing

@Test("Explicit private IPv4 endpoints remain untrusted candidates")
func explicitPrivateEndpoint() async throws {
    let endpoint = try PeerEndpoint(host: "192.168.1.8", port: 8443)
    let discovery = BonjourPeerDiscovery()

    let candidate = try await discovery.candidate(for: endpoint)

    #expect(candidate.serviceName == "manual")
    #expect(candidate.endpoint == endpoint)
}

@Test("Explicit local IPv4 ranges are accepted")
func explicitLocalIPv4Ranges() throws {
    let validator = LANEndpointValidator(permitsLoopback: false)
    let hosts = ["10.0.0.1", "172.16.0.1", "172.31.255.254", "169.254.10.2"]

    for host in hosts {
        let endpoint = try PeerEndpoint(host: host, port: 443)
        #expect(try validator.validate(endpoint) == endpoint)
    }
}

@Test(
    "Public, DNS, and loopback endpoints are rejected by default",
    arguments: [
        "8.8.8.8", "example.com", "127.0.0.1", "172.32.0.1",
    ])
func rejectsNonLANEndpoint(host: String) async throws {
    let endpoint = try PeerEndpoint(host: host, port: 8443)
    let discovery = BonjourPeerDiscovery()

    await #expect(throws: PeerDiscoveryError.self) {
        try await discovery.candidate(for: endpoint)
    }
}

@Test("Loopback can be enabled only through explicit configuration")
func permitsConfiguredLoopback() async throws {
    let endpoint = try PeerEndpoint(host: "::1", port: 8443)
    let discovery = BonjourPeerDiscovery(
        configuration: .init(permitsLoopback: true)
    )

    let candidate = try await discovery.candidate(for: endpoint)

    #expect(candidate.endpoint == endpoint)
}

@Test("Discovery rejects an unbounded stream request")
func rejectsInvalidDiscoveryBuffer() async {
    let discovery = BonjourPeerDiscovery()

    await #expect(throws: PeerDiscoveryError.invalidBufferingLimit) {
        _ = try await discovery.discover(bufferingLimit: 0)
    }
}

@Test("Resolution policy rejects invalid limits")
func rejectsInvalidResolutionPolicy() {
    #expect(throws: PeerDiscoveryError.invalidConfiguration) {
        try BonjourResolutionPolicy(timeout: 0, maximumAttempts: 1, retryDelay: 0)
    }
    #expect(throws: PeerDiscoveryError.invalidConfiguration) {
        try BonjourResolutionPolicy(timeout: 1, maximumAttempts: 0, retryDelay: 0)
    }
}

@Test("Resolution retries a transient failure")
func retriesResolutionFailure() async throws {
    let counter = ResolutionAttemptCounter()
    let policy = try BonjourResolutionPolicy(
        timeout: 1,
        maximumAttempts: 2,
        retryDelay: 0
    )

    let value = try await ResolutionAttemptRunner.run(policy: policy) { _ in
        let attempt = await counter.increment()
        guard attempt > 1 else { throw PeerDiscoveryError.resolutionFailed }
        return "resolved"
    }

    #expect(value == "resolved")
    #expect(await counter.value == 2)
}

@Test("Resolution attempt observes its deadline")
func timesOutResolutionAttempt() async throws {
    let policy = try BonjourResolutionPolicy(
        timeout: 0.001,
        maximumAttempts: 1,
        retryDelay: 0
    )

    await #expect(throws: PeerDiscoveryError.resolutionFailed) {
        _ = try await ResolutionAttemptRunner.run(policy: policy) { _ in
            try await Task.sleep(for: .seconds(30))
            return "late"
        }
    }
}

@MainActor
@Test("Advertisement rejects empty service names")
func rejectsEmptyAdvertisementName() {
    #expect(throws: PeerDiscoveryError.invalidServiceName) {
        _ = try BonjourServiceAdvertiser(serviceName: "  ", port: 8443)
    }
}

@MainActor
@Test("Advertisement event streams must be bounded")
func rejectsInvalidAdvertisementBuffer() throws {
    let advertiser = try BonjourServiceAdvertiser(serviceName: "Mac", port: 8443)

    #expect(throws: PeerDiscoveryError.invalidBufferingLimit) {
        _ = try advertiser.events(bufferingLimit: 0)
    }
}

@MainActor
@Test("Stale advertisement callbacks cannot clear an active service")
func ignoresStaleAdvertisementCallbacks() throws {
    let advertiser = try BonjourServiceAdvertiser(
        serviceName: "Mac",
        port: 8443,
        publishService: { _ in },
        stopService: { _ in }
    )
    let staleService = NetService(
        domain: "local.",
        type: BonjourDiscoveryConfiguration.serviceType,
        name: "stale",
        port: 8443
    )
    try advertiser.start()
    defer { advertiser.stop() }

    advertiser.netServiceDidStop(staleService)

    #expect(throws: PeerDiscoveryError.advertisementAlreadyActive) {
        try advertiser.start()
    }
}

private actor ResolutionAttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

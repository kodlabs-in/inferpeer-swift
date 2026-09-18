@testable import InferPeerGRPC
import Testing

@Suite("Wi-Fi path enforcement")
struct WiFiPathMonitorTests {
    @Test("initial transient snapshots do not terminate a session")
    func initialTransientIsIgnored() {
        var state = WiFiPathEnforcementState()

        let firstToken = state.observe(isAllowed: false)
        let secondToken = state.observe(isAllowed: false)

        #expect(firstToken == nil)
        #expect(secondToken == nil)
        #expect(!state.hasObservedAllowedPath)
    }

    @Test("sustained path loss terminates after the grace window")
    func sustainedPathLossTerminates() throws {
        var state = WiFiPathEnforcementState()

        let establishedToken = state.observe(isAllowed: true)
        let pendingToken = state.observe(isAllowed: false)
        let lostToken = try #require(pendingToken)
        let shouldTerminate = state.confirmDisallowedPath(token: lostToken)

        #expect(establishedToken == nil)
        #expect(state.hasObservedAllowedPath)
        #expect(shouldTerminate)
    }

    @Test("an allowed update cancels a pending path-loss shutdown")
    func transientPathLossIsCancelled() throws {
        var state = WiFiPathEnforcementState()

        _ = state.observe(isAllowed: true)
        let pendingToken = state.observe(isAllowed: false)
        let lostToken = try #require(pendingToken)
        let restoredToken = state.observe(isAllowed: true)
        let shouldTerminate = state.confirmDisallowedPath(token: lostToken)

        #expect(restoredToken == nil)
        #expect(!shouldTerminate)
    }

    @Test("repeated disallowed updates schedule only one revalidation")
    func repeatedPathLossIsCoalesced() throws {
        var state = WiFiPathEnforcementState()

        _ = state.observe(isAllowed: true)
        let pendingToken = state.observe(isAllowed: false)
        let firstToken = try #require(pendingToken)
        let repeatedToken = state.observe(isAllowed: false)
        let shouldTerminate = state.confirmDisallowedPath(token: firstToken)

        #expect(repeatedToken == nil)
        #expect(shouldTerminate)
    }
}

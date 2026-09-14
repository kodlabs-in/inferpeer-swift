@testable import InferPeer
@testable import InferPeerCore
@testable import InferPeerDiscovery
@testable import InferPeerGRPC
@testable import InferPeerInference
@testable import InferPeerMLX
@testable import InferPeerProtocol
@testable import InferPeerSecurity
@testable import InferPeerStorage
@testable import InferPeerTelemetry
import Testing

@Test("All ten library modules are importable")
func allLibraryModulesAreImportable() {
    let modules: [Any.Type] = [
        InferPeerModule.self,
        InferPeerProtocolModule.self,
        InferPeerInferenceModule.self,
        InferPeerCoreModule.self,
        InferPeerGRPCModule.self,
        InferPeerStorageModule.self,
        InferPeerDiscoveryModule.self,
        InferPeerSecurityModule.self,
        InferPeerTelemetryModule.self,
        InferPeerMLXModule.self,
    ]

    #expect(modules.count == 10)
}

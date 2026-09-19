@testable import InferPeer
@testable import InferPeerCore
@testable import InferPeerDiscovery
@testable import InferPeerGRPC
@testable import InferPeerInference
@testable import InferPeerMLX
@testable import InferPeerModelStore
@testable import InferPeerProtocol
@testable import InferPeerSecurity
@testable import InferPeerStorage
@testable import InferPeerTelemetry
import Testing

@Test("All eleven library modules are importable")
func allLibraryModulesAreImportable() {
    let modules: [Any.Type] = [
        InferPeerModule.self,
        InferPeerProtocolVersion.self,
        InferPeerInferenceModule.self,
        InferPeerCoreModule.self,
        InferPeerGRPCModule.self,
        InferPeerStorageModule.self,
        InferPeerDiscoveryModule.self,
        InferPeerSecurityModule.self,
        InferPeerTelemetryModule.self,
        RuntimeID.self,
        InferPeerMLXModule.self,
    ]

    #expect(modules.count == 11)
}

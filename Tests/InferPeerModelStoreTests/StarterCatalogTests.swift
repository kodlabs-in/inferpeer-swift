import Foundation
import InferPeerInference
@testable import InferPeerModelStore
import Testing

@Suite("Signed starter catalog")
struct StarterCatalogTests {
    @Test("Bundled envelope verifies against its pinned key")
    func verifiesBundledEnvelope() throws {
        let bundle = try InferPeerStarterCatalog.load()
        let catalog = try ModelCatalogVerifier(
            trustedKeys: bundle.trustedCatalogKeys
        ).verify(bundle.signedCatalog)

        #expect(catalog.revision == "starter-2026-09-19.4")
        #expect(catalog.entries.count == 3)
        let stable = try #require(catalog.entries.first(where: { $0.metadata.status == .stable }))
        #expect(stable.manifest.upstreamRevision == Self.mlxRevision)
        #expect(stable.approximateDownloadBytes == 351_383_618)
    }

    @Test("Stable artifact pins every immutable source byte")
    func pinsEverySourceByte() throws {
        let bundle = try InferPeerStarterCatalog.load()
        let catalog = try ModelCatalogVerifier(
            trustedKeys: bundle.trustedCatalogKeys
        ).verify(bundle.signedCatalog)
        let entry = try #require(catalog.entries.first(where: {
            $0.manifest.runtime.runtimeIdentifier == "mlx"
        }))

        #expect(entry.downloadFiles.count == 9)
        #expect(entry.downloadFiles.allSatisfy { $0.url.scheme == "https" })
        #expect(entry.downloadFiles.allSatisfy { $0.url.absoluteString.contains(Self.mlxRevision) })
        #expect(entry.validation.map(\.hardwareIdentifier) == [
            "iPhone15,4", "iPad14,3", "Mac17,2",
        ])
    }

    @Test("Native runtime artifacts have immutable complete declarations")
    func pinsNativeArtifacts() throws {
        let catalog = try ModelCatalogVerifier(
            trustedKeys: InferPeerStarterCatalog.load().trustedCatalogKeys
        ).verify(InferPeerStarterCatalog.load().signedCatalog)
        let llama = try #require(catalog.entries.first(where: {
            $0.manifest.runtime.runtimeIdentifier == "llama.cpp"
        }))
        let whisper = try #require(catalog.entries.first(where: {
            $0.manifest.runtime.runtimeIdentifier == "whisperkit"
        }))

        #expect(llama.approximateDownloadBytes == 639_446_688)
        #expect(llama.downloadFiles.count == 1)
        #expect(whisper.approximateDownloadBytes == 150_901_485)
        #expect(whisper.downloadFiles.count == 26)
        #expect(whisper.manifest.license == "MIT AND Apache-2.0")
    }

    private static let mlxRevision = "73e3e38d981303bc594367cd910ea6eb48349da8"
}

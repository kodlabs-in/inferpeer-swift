import Foundation
import InferPeerApple
import InferPeerModelStore
import Testing

@Suite("Apple device profiler")
struct AppleDeviceProfilerTests {
    @Test("Reports actual local resource facts")
    func reportsLocalFacts() throws {
        let profiler = AppleDeviceProfiler(storageURL: FileManager.default.temporaryDirectory)

        let snapshot = try profiler.snapshot()

        #expect(snapshot.modelStoreProfile.resourceID == .local)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(
            snapshot.platform.operatingSystemVersion
                == "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        #expect(snapshot.modelStoreProfile.physicalMemoryBytes == physicalMemory)
        #expect(snapshot.modelStoreProfile.freeStorageBytes != nil)
        #expect(snapshot.telemetry.measurements[
            ModelStoreDeviceProfile.physicalMemoryMeasurement
        ]?.quality == .measured)
        #if arch(arm64)
            #expect(snapshot.chipFeatures.contains("apple-silicon"))
        #endif
    }

    @Test("Provides process memory admission input")
    func providesMemoryHeadroom() async throws {
        let profiler = AppleDeviceProfiler(storageURL: FileManager.default.temporaryDirectory)

        let value = await profiler.safeAdditionalMemoryBytes()

        #expect(value != nil)
        #expect(value ?? 0 > 0)
    }
}

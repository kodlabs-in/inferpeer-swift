import Foundation
import InferPeerStorage
import Testing

@Suite("SQLite direct asset store")
struct SQLiteDirectAssetStoreTests {
    @Test("Upload resumes from the durable offset and publishes only after hash verification")
    func resumableVerifiedUpload() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let descriptor = try makeAssetDescriptor()
        let firstStore = try database.makeDirectAssetStore()
        let ticket = try await firstStore.prepare(descriptor)

        let firstOffset = try await firstStore.append(
            Data("abc".utf8),
            to: ticket,
            ownerID: descriptor.ownerID,
            offset: 0
        )
        #expect(firstOffset == 3)

        let reopened = try database.makeDirectAssetStore()
        #expect(try await reopened.status(ticket, ownerID: descriptor.ownerID).durableOffset == 3)
        let finalOffset = try await reopened.append(
            Data("def".utf8),
            to: ticket,
            ownerID: descriptor.ownerID,
            offset: 3
        )
        #expect(finalOffset == 6)

        let receipt = try await reopened.finalize(ticket, ownerID: descriptor.ownerID)
        let bytes = try await reopened.read(
            receipt,
            ownerID: descriptor.ownerID,
            offset: 0,
            length: 6
        )
        #expect(bytes == Data("abcdef".utf8))
        await #expect(throws: DirectAssetStoreError.accessDenied) {
            _ = try await reopened.read(
                receipt,
                ownerID: "paired-app-b",
                offset: 0,
                length: 6
            )
        }
    }

    @Test("Offset mismatches and cross-owner access fail closed")
    func offsetAndOwnerIsolation() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let store = try database.makeDirectAssetStore()
        let descriptor = try makeAssetDescriptor()
        let ticket = try await store.prepare(descriptor)

        await #expect(throws: DirectAssetStoreError.uploadOffsetMismatch) {
            _ = try await store.append(
                Data("abc".utf8),
                to: ticket,
                ownerID: descriptor.ownerID,
                offset: 1
            )
        }
        await #expect(throws: DirectAssetStoreError.accessDenied) {
            _ = try await store.status(ticket, ownerID: "paired-app-b")
        }
    }

    @Test("A hash mismatch never publishes a receipt")
    func corruptUploadIsDiscarded() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let store = try database.makeDirectAssetStore()
        let descriptor = try makeAssetDescriptor(sha256: Data(repeating: 0, count: 32))
        let ticket = try await store.prepare(descriptor)
        _ = try await store.append(
            Data("abcdef".utf8),
            to: ticket,
            ownerID: descriptor.ownerID,
            offset: 0
        )

        await #expect(throws: DirectAssetStoreError.assetInvalid) {
            _ = try await store.finalize(ticket, ownerID: descriptor.ownerID)
        }
        await #expect(throws: DirectAssetStoreError.ticketNotFound) {
            _ = try await store.status(ticket, ownerID: descriptor.ownerID)
        }
    }

    @Test("Expired incomplete assets are removed with their private files")
    func expiredAssetsAreCleanedUp() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let store = try database.makeDirectAssetStore(date: Date(timeIntervalSince1970: 1_000))
        let descriptor = try makeAssetDescriptor(sha256: Data(repeating: 0, count: 32))
        let ticket = try await store.prepare(descriptor)
        let laterStore = try database.makeDirectAssetStore(
            date: Date(timeIntervalSince1970: 3_000)
        )

        #expect(try await laterStore.removeExpired() == 1)
        await #expect(throws: DirectAssetStoreError.ticketNotFound) {
            _ = try await laterStore.status(ticket, ownerID: descriptor.ownerID)
        }
    }
}

private func makeAssetDescriptor(sha256: Data? = nil) throws -> DirectAssetUploadDescriptor {
    let expectedHash =
        try sha256 ?? #require(
            Data(hex: "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721")
        )
    return try DirectAssetUploadDescriptor(
        ownerID: "paired-app-a",
        byteCount: 6,
        sha256: expectedHash,
        mediaType: "application/octet-stream",
        expiresAt: Date(timeIntervalSince1970: 2_000)
    )
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

import Crypto
import Foundation
import GRDB
import InferPeerInference

/// File-backed resumable assets with SQLite metadata and owner-scoped receipts.
public actor SQLiteDirectAssetStore {
    /// Maximum write or read payload handled in one operation.
    public static let maximumChunkBytes = 256 * 1_024

    private let database: DatabasePool
    private let assetDirectoryURL: URL
    private let dateProvider: any StorageDateProvider

    /// Opens metadata and prepares the private file-backed asset directory.
    public init(
        databaseURL: URL,
        assetDirectoryURL: URL,
        configuration: SQLiteStorageConfiguration = .standard,
        dateProvider: any StorageDateProvider = SystemStorageDateProvider()
    ) throws {
        database = try StorageConnection.open(
            databaseURL: databaseURL,
            configuration: configuration
        )
        self.assetDirectoryURL = assetDirectoryURL
        self.dateProvider = dateProvider
        try FileManager.default.createDirectory(
            at: assetDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

extension SQLiteDirectAssetStore {
    /// Reserves private storage and returns a random ticket.
    public func prepare(_ descriptor: DirectAssetUploadDescriptor) async throws
        -> DirectAssetUploadTicket
    {
        guard descriptor.expiresAt > dateProvider.now() else {
            throw DirectAssetStoreError.assetExpired
        }
        let ticket = DirectAssetUploadTicket(rawValue: UUID().uuidString.lowercased())
        let fileName = "\(UUID().uuidString.lowercased()).partial"
        let fileURL = assetDirectoryURL.appendingPathComponent(fileName)
        guard
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw DirectAssetStoreError.storageFailure
        }
        let timestamp = dateProvider.now()
        let record = DirectAssetRecord(
            ticket: ticket.rawValue,
            ownerID: descriptor.ownerID,
            expectedByteCount: String(descriptor.byteCount),
            expectedSHA256: descriptor.sha256,
            mediaType: descriptor.mediaType,
            expiresAt: descriptor.expiresAt,
            durableOffset: "0",
            fileName: fileName,
            receipt: nil,
            isComplete: false,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        do {
            try await database.write { database in
                try record.insert(database)
            }
            return ticket
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw DirectAssetStoreError.storageFailure
        }
    }

    /// Returns only the offset durably recorded by the resource.
    public func status(
        _ ticket: DirectAssetUploadTicket,
        ownerID: String
    ) async throws -> DirectAssetUploadStatus {
        let record = try await record(ticket: ticket, ownerID: ownerID)
        return try record.status()
    }

    /// Appends one bounded chunk at exactly the resource-confirmed offset.
    @discardableResult
    public func append(
        _ bytes: Data,
        to ticket: DirectAssetUploadTicket,
        ownerID: String,
        offset: UInt64
    ) async throws -> UInt64 {
        guard !bytes.isEmpty, bytes.count <= Self.maximumChunkBytes else {
            throw DirectAssetStoreError.chunkTooLarge
        }
        let record = try await incompleteRecord(ticket: ticket, ownerID: ownerID)
        let durableOffset = try record.parsedDurableOffset()
        let expectedByteCount = try record.parsedExpectedByteCount()
        guard offset == durableOffset else {
            throw DirectAssetStoreError.uploadOffsetMismatch
        }
        guard let chunkCount = UInt64(exactly: bytes.count),
            durableOffset <= expectedByteCount,
            chunkCount <= expectedByteCount - durableOffset
        else {
            throw DirectAssetStoreError.assetInvalid
        }
        let fileURL = assetDirectoryURL.appendingPathComponent(record.fileName)
        try normalizeFile(fileURL, durableOffset: durableOffset)
        try write(bytes, to: fileURL, offset: durableOffset)
        let newOffset = durableOffset + chunkCount
        do {
            try await database.write { database in
                try database.execute(
                    sql: """
                        UPDATE directAssetRecord
                        SET durableOffset = ?, updatedAt = ?
                        WHERE ticket = ?
                        """,
                    arguments: [String(newOffset), self.dateProvider.now(), ticket.rawValue]
                )
            }
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
        return newOffset
    }

    /// Verifies the complete file hash before atomically publishing an opaque receipt.
    public func finalize(
        _ ticket: DirectAssetUploadTicket,
        ownerID: String
    ) async throws -> InferenceAssetReceipt {
        let record = try await incompleteRecord(ticket: ticket, ownerID: ownerID)
        guard try record.parsedDurableOffset() == record.parsedExpectedByteCount() else {
            throw DirectAssetStoreError.assetInvalid
        }
        let partialURL = assetDirectoryURL.appendingPathComponent(record.fileName)
        guard try hash(of: partialURL) == record.expectedSHA256 else {
            try await discard(record)
            throw DirectAssetStoreError.assetInvalid
        }
        let receipt = InferenceAssetReceipt(rawValue: UUID().uuidString.lowercased())
        let completedName = "\(UUID().uuidString.lowercased()).asset"
        let completedURL = assetDirectoryURL.appendingPathComponent(completedName)
        do {
            try FileManager.default.moveItem(at: partialURL, to: completedURL)
            try await database.write { database in
                try database.execute(
                    sql: """
                        UPDATE directAssetRecord
                        SET fileName = ?, receipt = ?, isComplete = 1, updatedAt = ?
                        WHERE ticket = ?
                        """,
                    arguments: [
                        completedName,
                        receipt.rawValue,
                        self.dateProvider.now(),
                        ticket.rawValue,
                    ]
                )
            }
            return receipt
        } catch {
            try? FileManager.default.moveItem(at: completedURL, to: partialURL)
            throw DirectAssetStoreError.storageFailure
        }
    }

    /// Reads one bounded range after verifying receipt ownership and retention.
    public func read(
        _ receipt: InferenceAssetReceipt,
        ownerID: String,
        offset: UInt64,
        length: Int
    ) async throws -> Data {
        guard length > 0, length <= Self.maximumChunkBytes else {
            throw DirectAssetStoreError.readOutOfBounds
        }
        let record = try await completedRecord(receipt: receipt, ownerID: ownerID)
        let byteCount = try record.parsedExpectedByteCount()
        guard let readCount = UInt64(exactly: length),
            offset <= byteCount,
            readCount <= byteCount - offset
        else {
            throw DirectAssetStoreError.readOutOfBounds
        }
        let fileURL = assetDirectoryURL.appendingPathComponent(record.fileName)
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
    }

    /// Removes expired records and their untrusted or retained private files.
    @discardableResult
    public func removeExpired() async throws -> Int {
        let records: [DirectAssetRecord]
        do {
            records = try await database.read { database in
                try DirectAssetRecord
                    .filter(Column("expiresAt") <= self.dateProvider.now())
                    .fetchAll(database)
            }
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
        guard !records.isEmpty else { return 0 }
        for record in records {
            let fileURL = assetDirectoryURL.appendingPathComponent(record.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        do {
            try await database.write { database in
                let tickets = records.map(\.ticket)
                _ =
                    try DirectAssetRecord
                    .filter(tickets.contains(Column("ticket")))
                    .deleteAll(database)
            }
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
        return records.count
    }

    private func record(
        ticket: DirectAssetUploadTicket,
        ownerID: String
    ) async throws -> DirectAssetRecord {
        let record: DirectAssetRecord?
        do {
            record = try await database.read { database in
                try DirectAssetRecord.fetchOne(database, key: ticket.rawValue)
            }
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
        guard let record else { throw DirectAssetStoreError.ticketNotFound }
        try validate(record, ownerID: ownerID)
        return record
    }

    private func incompleteRecord(
        ticket: DirectAssetUploadTicket,
        ownerID: String
    ) async throws -> DirectAssetRecord {
        let record = try await record(ticket: ticket, ownerID: ownerID)
        guard !record.isComplete else { throw DirectAssetStoreError.assetInvalid }
        return record
    }

    private func completedRecord(
        receipt: InferenceAssetReceipt,
        ownerID: String
    ) async throws -> DirectAssetRecord {
        let record: DirectAssetRecord?
        do {
            record = try await database.read { database in
                try DirectAssetRecord
                    .filter(Column("receipt") == receipt.rawValue)
                    .fetchOne(database)
            }
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
        guard let record else { throw DirectAssetStoreError.ticketNotFound }
        try validate(record, ownerID: ownerID)
        guard record.isComplete else { throw DirectAssetStoreError.assetInvalid }
        return record
    }

    private func validate(_ record: DirectAssetRecord, ownerID: String) throws {
        guard record.ownerID == ownerID else { throw DirectAssetStoreError.accessDenied }
        guard record.expiresAt > dateProvider.now() else {
            throw DirectAssetStoreError.assetExpired
        }
    }

    private func normalizeFile(_ fileURL: URL, durableOffset: UInt64) throws {
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let actualOffset = try handle.seekToEnd()
            guard actualOffset >= durableOffset else {
                throw DirectAssetStoreError.assetInvalid
            }
            if actualOffset > durableOffset {
                try handle.truncate(atOffset: durableOffset)
                try handle.synchronize()
            }
        } catch let error as DirectAssetStoreError {
            throw error
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
    }

    private func write(_ bytes: Data, to fileURL: URL, offset: UInt64) throws {
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
    }

    private func hash(of fileURL: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: Self.maximumChunkBytes), !bytes.isEmpty {
                hasher.update(data: bytes)
            }
            return Data(hasher.finalize())
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
    }

    private func discard(_ record: DirectAssetRecord) async throws {
        let fileURL = assetDirectoryURL.appendingPathComponent(record.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        do {
            try await database.write { database in
                _ = try DirectAssetRecord.deleteOne(database, key: record.ticket)
            }
        } catch {
            throw DirectAssetStoreError.storageFailure
        }
    }
}

private struct DirectAssetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "directAssetRecord"

    let ticket: String
    let ownerID: String
    let expectedByteCount: String
    let expectedSHA256: Data
    let mediaType: String
    let expiresAt: Date
    let durableOffset: String
    let fileName: String
    let receipt: String?
    let isComplete: Bool
    let createdAt: Date
    let updatedAt: Date

    func parsedExpectedByteCount() throws -> UInt64 {
        guard let value = UInt64(expectedByteCount) else {
            throw DirectAssetStoreError.assetInvalid
        }
        return value
    }

    func parsedDurableOffset() throws -> UInt64 {
        guard let value = UInt64(durableOffset) else {
            throw DirectAssetStoreError.assetInvalid
        }
        return value
    }

    func status() throws -> DirectAssetUploadStatus {
        DirectAssetUploadStatus(
            durableOffset: try parsedDurableOffset(),
            expectedByteCount: try parsedExpectedByteCount(),
            receipt: receipt.map(InferenceAssetReceipt.init(rawValue:))
        )
    }
}

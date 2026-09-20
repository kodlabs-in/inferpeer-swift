import Crypto
import Foundation
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerProtocol

extension DirectResourceHostHandler {
    static let supportedImageMediaTypes: Set<String> = [
        "image/heic",
        "image/jpeg",
        "image/png",
    ]
    private static let imageMagicPrefixes: [String: [UInt8]] = [
        "image/jpeg": [0xFF, 0xD8, 0xFF],
        "image/png": [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    ]
    private static let heicBrands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"]

    // Service protocol operations remain async even when actor state is sufficient.
    // swiftlint:disable async_without_await
    /// Validates image declarations and creates owner-scoped upload tickets.
    public func prepareAssets(
        _ request: InferPeer_V2_PrepareAssetsRequest
    ) async throws -> InferPeer_V2_PrepareAssetsResponse {
        let principal = try requirePrincipal()
        guard !request.assets.isEmpty,
            request.assets.count <= InferenceQuery.maximumImageCount
        else {
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
        removeExpiredTickets()
        var seen: Set<String> = []
        for declaration in request.assets {
            try validate(declaration, seen: &seen)
        }
        try enforceAssetQuota(for: principal, declarations: request.assets)
        return makeAssetTickets(for: principal, declarations: request.assets)
    }

    private func makeAssetTickets(
        for principal: String,
        declarations: [InferPeer_V2_AssetDeclaration]
    ) -> InferPeer_V2_PrepareAssetsResponse {
        let now = Date()
        var response = InferPeer_V2_PrepareAssetsResponse()
        for declaration in declarations {
            let ticket = UUID().uuidString.lowercased()
            let expiresAt = now.addingTimeInterval(10 * 60)
            tickets[ticket] = AssetTicket(
                principalID: principal,
                clientID: declaration.clientAssetID,
                expectedBytes: declaration.byteCount,
                expectedDigest: declaration.sha256,
                mediaType: declaration.mediaType,
                expiresAt: expiresAt,
                data: Data()
            )
            response.tickets.append(
                InferPeer_V2_UploadTicket.with {
                    $0.ticket = ticket
                    $0.clientAssetID = declaration.clientAssetID
                    $0.durableOffset = 0
                    $0.expiresUnixMilliseconds = UInt64(
                        expiresAt.timeIntervalSince1970 * 1_000
                    )
                }
            )
        }
        return response
    }

    /// Receives one bounded image stream and returns an immutable receipt.
    public func uploadAsset(
        _ requests: DirectRPCStream<InferPeer_V2_UploadAssetRequest>
    ) async throws -> InferPeer_V2_UploadAssetResponse {
        let principal = try requirePrincipal()
        var activeTicket: String?
        for try await request in requests {
            try append(request, principal: principal, activeTicket: &activeTicket)
        }
        guard let activeTicket, let ticket = tickets[activeTicket],
            UInt64(ticket.data.count) == ticket.expectedBytes
        else {
            throw InferPeerError(code: .connectionLost, isRetryable: true)
        }
        let digest = Data(SHA256.hash(data: ticket.data))
        guard digest == ticket.expectedDigest else {
            tickets[activeTicket] = nil
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
        guard Self.hasValidImageSignature(ticket.data, mediaType: ticket.mediaType) else {
            tickets[activeTicket] = nil
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
        let receiptID = UUID().uuidString.lowercased()
        let url = try assetURL(principal: principal, receipt: receiptID)
        try ticket.data.write(to: url, options: .atomic)
        receipts[receiptID] = AssetReceipt(
            principalID: principal,
            url: url,
            byteCount: ticket.expectedBytes,
            digest: digest
        )
        tickets[activeTicket] = nil
        return InferPeer_V2_UploadAssetResponse.with {
            $0.receipt = receiptID
            $0.byteCount = ticket.expectedBytes
            $0.sha256 = digest
        }
    }

    /// Returns the durable offset for an active owner-scoped upload ticket.
    public func getUploadStatus(
        _ request: InferPeer_V2_GetUploadStatusRequest
    ) async throws -> InferPeer_V2_GetUploadStatusResponse {
        let principal = try requirePrincipal()
        guard let ticket = tickets[request.ticket], ticket.principalID == principal else {
            throw InferPeerError(code: .assetExpired, isRetryable: false)
        }
        return InferPeer_V2_GetUploadStatusResponse.with {
            $0.durableOffset = UInt64(ticket.data.count)
            $0.complete = false
        }
    }

    /// Rejects asset reads because v1 hosts expose inputs only to their runtime.
    public func readAsset(
        _: InferPeer_V2_ReadAssetRequest
    ) async throws -> DirectRPCStream<InferPeer_V2_ReadAssetResponse> {
        _ = try requirePrincipal()
        throw InferPeerError(code: .unsupportedTask, isRetryable: false)
    }

    /// Removes one owner-scoped asset receipt and its temporary file.
    public func releaseAsset(
        _ request: InferPeer_V2_ReleaseAssetRequest
    ) async throws -> InferPeer_V2_ReleaseAssetResponse {
        let principal = try requirePrincipal()
        guard let receipt = receipts[request.receipt] else {
            return InferPeer_V2_ReleaseAssetResponse.with { $0.released = false }
        }
        guard receipt.principalID == principal else {
            throw InferPeerError(code: .permissionDenied, isRetryable: false)
        }
        receipts[request.receipt] = nil
        try? FileManager.default.removeItem(at: receipt.url)
        return InferPeer_V2_ReleaseAssetResponse.with { $0.released = true }
    }

    func resolveAssets(
        in query: InferenceQuery,
        principal: String
    ) throws -> InferenceQuery {
        guard case .vision(let vision) = query else { return query }
        let images = try vision.images.map { reference -> InferenceAssetReference in
            guard case .receipt(let value) = reference,
                let receipt = receipts[value.rawValue]
            else {
                throw InferPeerError(code: .assetExpired, isRetryable: false)
            }
            guard receipt.principalID == principal else {
                throw InferPeerError(code: .permissionDenied, isRetryable: false)
            }
            return .file(receipt.url)
        }
        return .vision(
            VisionInferenceQuery(
                model: vision.model,
                messages: vision.messages,
                images: images,
                generation: vision.generation
            )
        )
    }

    private func append(
        _ request: InferPeer_V2_UploadAssetRequest,
        principal: String,
        activeTicket: inout String?
    ) throws {
        guard !request.data.isEmpty,
            activeTicket == nil || activeTicket == request.ticket,
            var ticket = tickets[request.ticket],
            ticket.principalID == principal,
            ticket.expiresAt > Date(),
            request.offset == UInt64(ticket.data.count),
            UInt64(ticket.data.count + request.data.count) <= ticket.expectedBytes
        else {
            throw InferPeerError(code: .uploadOffsetMismatch, isRetryable: false)
        }
        activeTicket = request.ticket
        ticket.data.append(request.data)
        tickets[request.ticket] = ticket
    }

    private func validate(
        _ declaration: InferPeer_V2_AssetDeclaration,
        seen: inout Set<String>
    ) throws {
        guard !declaration.clientAssetID.isEmpty,
            seen.insert(declaration.clientAssetID).inserted,
            declaration.byteCount > 0,
            declaration.byteCount <= Self.maximumAssetBytes,
            declaration.sha256.count == 32,
            Self.supportedImageMediaTypes.contains(declaration.mediaType)
        else {
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
    }

    private static func hasValidImageSignature(_ data: Data, mediaType: String) -> Bool {
        if let prefix = imageMagicPrefixes[mediaType] {
            return data.starts(with: prefix)
        }
        guard mediaType == "image/heic",
            data.count >= 12,
            data[4..<8].elementsEqual(Data("ftyp".utf8)),
            let brand = String(bytes: data[8..<12], encoding: .utf8)
        else { return false }
        return heicBrands.contains(brand)
    }

    private func assetURL(principal: String, receipt: String) throws -> URL {
        let directory = assetRoot.appendingPathComponent(principal, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory.appendingPathComponent(receipt, isDirectory: false)
        } catch {
            throw InferPeerError(code: .storageFull, isRetryable: true)
        }
    }

    private func enforceAssetQuota(
        for principal: String,
        declarations: [InferPeer_V2_AssetDeclaration]
    ) throws {
        let requested = try checkedSum(declarations.map(\.byteCount))
        let principalObjects = tickets.values.lazy
            .filter { $0.principalID == principal }
            .count + receipts.values.lazy.filter { $0.principalID == principal }.count
        let hostObjects = tickets.count + receipts.count
        let principalBytes = try checkedSum([
            try checkedSum(
                tickets.values.lazy
                    .filter { $0.principalID == principal }
                    .map(\.expectedBytes)
            ),
            try checkedSum(
                receipts.values.lazy
                    .filter { $0.principalID == principal }
                    .map(\.byteCount)
            ),
        ])
        let hostBytes = try checkedSum([
            try checkedSum(tickets.values.lazy.map(\.expectedBytes)),
            try checkedSum(receipts.values.lazy.map(\.byteCount)),
        ])
        guard principalObjects + declarations.count <= Self.maximumPrincipalAssetObjects,
            hostObjects + declarations.count <= Self.maximumHostAssetObjects,
            principalBytes <= Self.maximumPrincipalAssetBytes,
            hostBytes <= Self.maximumHostAssetBytes,
            requested <= Self.maximumPrincipalAssetBytes - principalBytes,
            requested <= Self.maximumHostAssetBytes - hostBytes
        else {
            throw InferPeerError(code: .resourceExhausted, isRetryable: true)
        }
    }

    private func checkedSum<S: Sequence>(_ values: S) throws -> UInt64
    where S.Element == UInt64 {
        try values.reduce(0) { total, value in
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw InferPeerError(code: .resourceExhausted, isRetryable: true)
            }
            return addition.partialValue
        }
    }

    private func removeExpiredTickets() {
        let now = Date()
        tickets = tickets.filter { $0.value.expiresAt > now }
    }
    // swiftlint:enable async_without_await
}

import Crypto
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension DirectGRPCSessionManager {
    func prepareAssets(
        in query: InferenceQuery,
        resourceID: ResourceID
    ) async throws -> InferenceQuery {
        guard case .vision(let vision) = query else { return query }
        let prepared = try vision.images.map(PreparedClientAsset.init)
        guard prepared.contains(where: { $0.requiresUpload }) else { return query }
        let session = try await session(for: resourceID)
        let uploads = prepared.filter(\.requiresUpload)
        let response = try await session.connection.prepareAssets(
            InferPeer_V2_PrepareAssetsRequest.with { request in
                request.assets = uploads.map(\.declaration)
            }
        )
        let tickets = Dictionary(
            uniqueKeysWithValues: response.tickets.map { ($0.clientAssetID, $0) }
        )
        var receipts: [InferenceAssetReference] = []
        for asset in prepared {
            if let receipt = asset.existingReceipt {
                receipts.append(.receipt(receipt))
                continue
            }
            guard let ticket = tickets[asset.clientID] else {
                throw InferPeerError(code: .protocolMismatch, isRetryable: false)
            }
            receipts.append(
                .receipt(
                    try await upload(
                        asset,
                        ticket: ticket,
                        connection: session.connection
                    )
                )
            )
        }
        return .vision(
            VisionInferenceQuery(
                model: vision.model,
                messages: vision.messages,
                images: receipts,
                generation: vision.generation
            )
        )
    }

    private func upload(
        _ asset: PreparedClientAsset,
        ticket: InferPeer_V2_UploadTicket,
        connection: any AuthenticatedDirectResourceRPC
    ) async throws -> InferenceAssetReceipt {
        guard ticket.durableOffset <= UInt64(asset.data.count) else {
            throw InferPeerError(code: .uploadOffsetMismatch, isRetryable: false)
        }
        let response = try await connection.uploadAsset { writer in
            var offset = Int(ticket.durableOffset)
            while offset < asset.data.count {
                try Task.checkCancellation()
                let end = min(offset + PreparedClientAsset.chunkBytes, asset.data.count)
                try await writer.write(
                    InferPeer_V2_UploadAssetRequest.with {
                        $0.ticket = ticket.ticket
                        $0.offset = UInt64(offset)
                        $0.data = asset.data.subdata(in: offset..<end)
                    }
                )
                offset = end
            }
        }
        guard response.byteCount == UInt64(asset.data.count),
            response.sha256 == asset.digest,
            !response.receipt.isEmpty
        else {
            throw InferPeerError(code: .assetInvalid, isRetryable: false)
        }
        return InferenceAssetReceipt(rawValue: response.receipt)
    }

    func releaseAssets(_ receipts: [String], resourceID: ResourceID) async {
        guard !receipts.isEmpty, let session = try? await session(for: resourceID) else {
            return
        }
        for receipt in Set(receipts) {
            _ = try? await session.connection.releaseAsset(
                InferPeer_V2_ReleaseAssetRequest.with { $0.receipt = receipt }
            )
        }
    }
}

private struct PreparedClientAsset: Sendable {
    static let maximumBytes = 32 * 1_024 * 1_024
    static let chunkBytes = 128 * 1_024

    let clientID: String
    let data: Data
    let digest: Data
    let mediaType: String
    let existingReceipt: InferenceAssetReceipt?

    var requiresUpload: Bool { existingReceipt == nil }

    var declaration: InferPeer_V2_AssetDeclaration {
        InferPeer_V2_AssetDeclaration.with {
            $0.clientAssetID = clientID
            $0.byteCount = UInt64(data.count)
            $0.sha256 = digest
            $0.mediaType = mediaType
        }
    }

    init(_ reference: InferenceAssetReference) throws {
        clientID = UUID().uuidString.lowercased()
        switch reference {
        case .receipt(let receipt):
            data = Data()
            digest = Data()
            mediaType = ""
            existingReceipt = receipt
        case .file(let url):
            guard url.isFileURL else {
                throw InferPeerError(code: .assetInvalid, isRetryable: false)
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty, data.count <= Self.maximumBytes else {
                throw InferPeerError(code: .inputTooLarge, isRetryable: false)
            }
            self.data = data
            digest = Data(SHA256.hash(data: data))
            mediaType = Self.mediaType(for: url.pathExtension)
            existingReceipt = nil
        }
    }

    private static func mediaType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic", "heif": "image/heic"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }
}

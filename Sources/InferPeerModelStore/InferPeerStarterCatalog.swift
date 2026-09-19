import Foundation
import InferPeerInference
import InferPeerProtocol

// The signed catalog is immutable data; splitting it would obscure its signed canonical payload.
// swiftlint:disable file_length

/// Verified inputs for opening a model store with InferPeer's bundled starter catalog.
public struct InferPeerStarterCatalogBundle: Sendable {
    /// Signed exact catalog payload.
    public let signedCatalog: SignedModelCatalog
    /// Pinned catalog-signing public keys.
    public let trustedCatalogKeys: [String: Data]

    /// Creates immutable built-in catalog inputs.
    public init(
        signedCatalog: SignedModelCatalog,
        trustedCatalogKeys: [String: Data]
    ) {
        self.signedCatalog = signedCatalog
        self.trustedCatalogKeys = trustedCatalogKeys
    }
}

/// Package-owned, cryptographically signed starter artifacts.
public enum InferPeerStarterCatalog {
    /// Stable identity of the offline catalog-signing public key.
    public static let signingKeyID = "inferpeer-starter-2026-09-v6"

    /// Reconstructs and verifies the deterministic catalog envelope shipped by this package.
    public static func load() throws -> InferPeerStarterCatalogBundle {
        let payload = try ModelCatalogVerifier.encode(unsignedCatalog())
        guard let key = Data(base64Encoded: publicKeyBase64),
            let signature = Data(base64Encoded: signatureBase64)
        else {
            throw InferPeerStarterCatalogError.invalidEmbeddedMetadata
        }
        let envelope = SignedModelCatalog(
            keyID: signingKeyID,
            payload: payload,
            signature: signature
        )
        let trustedKeys = [signingKeyID: key]
        _ = try ModelCatalogVerifier(trustedKeys: trustedKeys).verify(envelope)
        return InferPeerStarterCatalogBundle(
            signedCatalog: envelope,
            trustedCatalogKeys: trustedKeys
        )
    }
}

/// Fail-closed errors for package-embedded catalog constants.
public enum InferPeerStarterCatalogError: Error, Equatable, Sendable {
    case invalidEmbeddedMetadata
}

private extension InferPeerStarterCatalog {
    static let mlxRevision = "73e3e38d981303bc594367cd910ea6eb48349da8"
    static let llamaRevision = "1eaf4d9657fe65ad10a51eab76a8db5b363bddaa"
    static let visionRevision = "ccd7aae53bcb1997355c2f094959e72b3642ce17"
    static let whisperRevision = "3b6e0975f1e819b577dbf25379597f2f4022cb42"
    static let whisperTokenizerRevision = "e37978b90ca9030d5170a5c07aadb050351a65bb"
    static let publicKeyBase64 = "TAfQ1Hg9V2ciMhyROA3n1mh4XAAWXufjfBnkA5GoiXo="
    static let signatureBase64 =
        "5TYY+bhxA0RfiXcDxITD6YwUTQaCxhJieclfAu79ofW3+7PtSJ/zDc69WKDKGfUDejvPMb3pk5KSbCG3FpAwDw=="

    struct Declaration {
        let manifest: ModelManifestFile
        let download: ModelDownloadFile
    }

}

extension InferPeerStarterCatalog {
    static func unsignedCatalog() throws -> ModelCatalog {
        try ModelCatalog(
            revision: "starter-2026-09-19.6",
            generatedAt: Date(timeIntervalSince1970: 1_789_776_000),
            entries: [mlxEntry(), llamaEntry(), visionEntry()]
        )
    }
}

private extension InferPeerStarterCatalog {

    static func mlxEntry() throws -> ModelCatalogEntry {
        let manifest = try mlxManifest()
        let files = try mlxDeclarations()
        return try ModelCatalogEntry(
            metadata: ModelCatalogMetadata(
                key: ModelCatalogKey(modelID: manifest.modelID, version: "1.0.0"),
                displayName: "Qwen3 0.6B 4-bit",
                publisher: "mlx-community / Qwen",
                status: .stable,
                recommendedTier: .iPhone
            ),
            manifest: manifest,
            downloadFiles: files.map(\.download),
            license: ModelLicense(
                identifier: "Apache-2.0",
                url: try url(
                    "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/blob/"
                        + mlxRevision + "/LICENSE"
                ),
                acceptanceRequired: false
            ),
            requirements: mlxRequirements(),
            validation: mlxValidations()
        )
    }

    static func mlxManifest() throws -> ModelManifest {
        try ModelManifest(
            modelID: try identifier(ModelID.self, "mlx-community-qwen3-0.6b-4bit"),
            family: "Qwen3",
            name: "Qwen3 0.6B 4-bit MLX",
            upstreamRevision: mlxRevision,
            source: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/tree/"
                + mlxRevision,
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "mlx",
                format: "MLX",
                quantization: "4-bit group-size-64",
                minimumBackendVersion: "0.2.0"
            ),
            files: try mlxDeclarations().map(\.manifest),
            capabilities: [
                try ModelTaskCapability(
                    task: .textGeneration,
                    contextTokenLimit: 40_960,
                    maximumOutputTokens: 4_096,
                    inputFormats: ["text"],
                    outputFormats: ["text"]
                )
            ]
        )
    }

    static func mlxRequirements() -> ModelRequirements {
        ModelRequirements(
            minimumOperatingSystems: [
                MinimumOperatingSystem(operatingSystem: .iOS, version: "18.0"),
                MinimumOperatingSystem(operatingSystem: .iPadOS, version: "18.0"),
                MinimumOperatingSystem(operatingSystem: .macOS, version: "15.0"),
            ],
            requiredChipFeatures: ["apple-silicon"],
            resources: ModelResourceRequirements(
                minimumPhysicalMemoryBytes: 3_000_000_000,
                minimumAvailableMemoryBytes: 1_500_000_000,
                minimumFreeStorageBytes: 704_000_000
            )
        )
    }

    static func mlxValidations() -> [ModelValidationRecord] {
        [
            ("iPhone15,4", "26.5.2"),
            ("iPad14,3", "27.0"),
            ("Mac17,2", "27.0"),
        ].map {
            ModelValidationRecord(
                hardwareIdentifier: $0.0,
                operatingSystemVersion: $0.1,
                adapterVersion: "0.2.0",
                passedAt: Date(timeIntervalSince1970: 1_789_689_600)
            )
        }
    }

    // Keep signed file hashes beside names so catalog review remains auditable.
    // swiftlint:disable large_tuple function_body_length
    static func mlxDeclarations() throws -> [Declaration] {
        let base =
            "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/"
            + mlxRevision
        let values: [(String, ModelManifestFileRole, UInt64, String)] = [
            (
                "added_tokens.json", .otherData, 707,
                "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"
            ),
            (
                "config.json", .runtimeConfiguration, 937,
                "15d3ac26c043ae477273ed5802ee0f0b33bb14f18c9d3dd70910c02d906e3f1f"
            ),
            (
                "merges.txt", .otherData, 1_671_853,
                "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
            ),
            (
                "model.safetensors", .weights, 335_450_584,
                "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2"
            ),
            (
                "model.safetensors.index.json", .otherData, 49_731,
                "7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb"
            ),
            (
                "special_tokens_map.json", .otherData, 613,
                "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"
            ),
            (
                "tokenizer.json", .tokenizer, 11_422_654,
                "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            ),
            (
                "tokenizer_config.json", .chatTemplate, 9_706,
                "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"
            ),
            (
                "vocab.json", .otherData, 2_776_833,
                "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            ),
        ]
        return try values.map { value in
            let digest = try ModelContentDigest(bytes: hex(value.3))
            return Declaration(
                manifest: try ModelManifestFile(
                    relativePath: value.0,
                    role: value.1,
                    byteCount: value.2,
                    sha256: digest
                ),
                download: try ModelDownloadFile(
                    relativePath: value.0,
                    url: try url("\(base)/\(value.0)?download=true"),
                    byteCount: value.2,
                    sha256: digest
                )
            )
        }
    }
    // swiftlint:enable large_tuple function_body_length

    static func llamaEntry() throws -> ModelCatalogEntry {
        let manifest = try llamaManifest()
        let files = try llamaDeclarations()
        return try ModelCatalogEntry(
            metadata: ModelCatalogMetadata(
                key: ModelCatalogKey(modelID: manifest.modelID, version: "1.0.0"),
                displayName: "Qwen3 0.6B Q8 native",
                publisher: "Qwen",
                status: .beta,
                recommendedTier: .iPhone
            ),
            manifest: manifest,
            downloadFiles: files.map(\.download),
            license: ModelLicense(
                identifier: "Apache-2.0",
                url: try url(
                    "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/blob/"
                        + llamaRevision + "/LICENSE"
                ),
                acceptanceRequired: false
            ),
            requirements: llamaRequirements()
        )
    }

    static func llamaManifest() throws -> ModelManifest {
        try ModelManifest(
            modelID: try identifier(ModelID.self, "qwen-qwen3-0.6b-q8-gguf"),
            family: "Qwen3",
            name: "Qwen3 0.6B Q8_0 GGUF",
            upstreamRevision: llamaRevision,
            source: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/tree/" + llamaRevision,
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "llama.cpp",
                format: "GGUF",
                quantization: "Q8_0",
                minimumBackendVersion: "b10982.1"
            ),
            files: try llamaDeclarations().map(\.manifest),
            capabilities: [
                try ModelTaskCapability(
                    task: .textGeneration,
                    contextTokenLimit: 32_768,
                    maximumOutputTokens: 4_096,
                    inputFormats: ["text"],
                    outputFormats: ["text"]
                )
            ]
        )
    }

    static func llamaDeclarations() throws -> [Declaration] {
        let name = "Qwen3-0.6B-Q8_0.gguf"
        let source =
            "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/"
            + llamaRevision + "/" + name + "?download=true"
        return [
            try declaration(
                path: name,
                role: .weights,
                bytes: 639_446_688,
                digest: "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031",
                source: source
            )
        ]
    }

    static func llamaRequirements() -> ModelRequirements {
        ModelRequirements(
            minimumOperatingSystems: supportedOperatingSystems(),
            requiredChipFeatures: ["apple-silicon"],
            resources: ModelResourceRequirements(
                minimumPhysicalMemoryBytes: 3_000_000_000,
                minimumAvailableMemoryBytes: 1_600_000_000,
                minimumFreeStorageBytes: 1_280_000_000
            )
        )
    }

    static func visionEntry() throws -> ModelCatalogEntry {
        let manifest = try visionManifest()
        let files = try visionDeclarations()
        return try ModelCatalogEntry(
            metadata: ModelCatalogMetadata(
                key: ModelCatalogKey(modelID: manifest.modelID, version: "1.0.0"),
                displayName: "SmolVLM2 500M Q8",
                publisher: "ggml.org / Hugging Face",
                status: .stable,
                recommendedTier: .iPhone
            ),
            manifest: manifest,
            downloadFiles: files.map(\.download),
            license: ModelLicense(
                identifier: "Apache-2.0",
                url: try url(
                    "https://huggingface.co/HuggingFaceTB/"
                        + "SmolVLM2-500M-Video-Instruct/blob/"
                        + "7b375e1b73b11138ff12fe22c8f2822d8fe03467/README.md"
                ),
                acceptanceRequired: false
            ),
            requirements: visionRequirements(),
            validation: visionValidations()
        )
    }

    static func visionManifest() throws -> ModelManifest {
        try ModelManifest(
            modelID: try identifier(ModelID.self, "ggml-smolvlm2-500m-q8-gguf"),
            family: "SmolVLM2",
            name: "SmolVLM2 500M Video Instruct Q8_0",
            upstreamRevision: visionRevision,
            source: "https://huggingface.co/ggml-org/"
                + "SmolVLM2-500M-Video-Instruct-GGUF/tree/" + visionRevision,
            license: "Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "llama.cpp",
                format: "GGUF",
                quantization: "Q8_0",
                minimumBackendVersion: "b10982.1"
            ),
            files: try visionDeclarations().map(\.manifest),
            capabilities: [
                try ModelTaskCapability(
                    task: .textGeneration,
                    contextTokenLimit: 8_192,
                    maximumOutputTokens: 1_024,
                    inputFormats: ["text"],
                    outputFormats: ["text"]
                ),
                try ModelTaskCapability(
                    task: .imageUnderstanding,
                    contextTokenLimit: 8_192,
                    maximumOutputTokens: 1_024,
                    maximumInputAssets: 4,
                    inputFormats: ["text", "image/jpeg", "image/png", "image/heic"],
                    outputFormats: ["text"]
                ),
            ]
        )
    }

    static func visionDeclarations() throws -> [Declaration] {
        let base =
            "https://huggingface.co/ggml-org/"
            + "SmolVLM2-500M-Video-Instruct-GGUF/resolve/" + visionRevision
        return [
            try declaration(
                path: "SmolVLM2-500M-Video-Instruct-Q8_0.gguf",
                role: .weights,
                bytes: 436_808_704,
                digest: "6f67b8036b2469fcd71728702720c6b51aebd759b78137a8120733b4d66438bc",
                source: base + "/SmolVLM2-500M-Video-Instruct-Q8_0.gguf?download=true"
            ),
            try declaration(
                path: "mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf",
                role: .projector,
                bytes: 108_785_184,
                digest: "921dc7e259f308e5b027111fa185efcbf33db13f6e35749ddf7f5cdb60ef520b",
                source: base
                    + "/mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf?download=true"
            ),
        ]
    }

    static func visionRequirements() -> ModelRequirements {
        ModelRequirements(
            minimumOperatingSystems: supportedOperatingSystems(),
            requiredChipFeatures: ["apple-silicon"],
            resources: ModelResourceRequirements(
                minimumPhysicalMemoryBytes: 3_000_000_000,
                minimumAvailableMemoryBytes: 1_500_000_000,
                minimumFreeStorageBytes: 1_100_000_000
            )
        )
    }

    static func visionValidations() -> [ModelValidationRecord] {
        [
            ("iPhone15,4", "26.5.2"),
            ("Mac17,2", "27.0"),
        ].map {
            ModelValidationRecord(
                hardwareIdentifier: $0.0,
                operatingSystemVersion: $0.1,
                adapterVersion: "b10982.1",
                passedAt: Date(timeIntervalSince1970: 1_789_776_000)
            )
        }
    }

    static func whisperEntry() throws -> ModelCatalogEntry {
        let manifest = try whisperManifest()
        let files = try whisperDeclarations()
        return try ModelCatalogEntry(
            metadata: ModelCatalogMetadata(
                key: ModelCatalogKey(modelID: manifest.modelID, version: "1.0.1"),
                displayName: "Whisper Base Core ML",
                publisher: "Argmax / OpenAI",
                status: .beta,
                recommendedTier: .iPad
            ),
            manifest: manifest,
            downloadFiles: files.map(\.download),
            license: ModelLicense(
                identifier: "MIT AND Apache-2.0",
                url: try url(
                    "https://github.com/argmaxinc/argmax-oss-swift/blob/"
                        + "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/LICENSE.md"
                ),
                acceptanceRequired: false
            ),
            requirements: whisperRequirements()
        )
    }

    static func whisperManifest() throws -> ModelManifest {
        try ModelManifest(
            modelID: try identifier(ModelID.self, "argmax-openai-whisper-base-coreml"),
            family: "Whisper",
            name: "Whisper Base Core ML",
            upstreamRevision: whisperRevision + "+" + whisperTokenizerRevision,
            source: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/"
                + whisperRevision + "/openai_whisper-base",
            license: "MIT AND Apache-2.0",
            runtime: ModelManifestRuntime(
                runtimeIdentifier: "whisperkit",
                format: "CoreML",
                quantization: "fp16",
                minimumBackendVersion: "1.1.0.1"
            ),
            files: try whisperDeclarations().map(\.manifest),
            capabilities: [
                try ModelTaskCapability(
                    task: .transcribe,
                    inputFormats: ["audio/m4a", "audio/mp3", "audio/wav"],
                    outputFormats: ["text"]
                )
            ]
        )
    }

    static func whisperRequirements() -> ModelRequirements {
        ModelRequirements(
            minimumOperatingSystems: supportedOperatingSystems(),
            requiredChipFeatures: ["apple-silicon"],
            resources: ModelResourceRequirements(
                minimumPhysicalMemoryBytes: 4_000_000_000,
                minimumAvailableMemoryBytes: 1_000_000_000,
                minimumFreeStorageBytes: 350_000_000
            )
        )
    }

    static func whisperDeclarations() throws -> [Declaration] {
        try whisperCoreMLDeclarations() + whisperTokenizerDeclarations()
    }

    // Keep signed file hashes beside names so catalog review remains auditable.
    // swiftlint:disable large_tuple function_body_length
    static func whisperCoreMLDeclarations() throws -> [Declaration] {
        let values: [(String, ModelManifestFileRole, UInt64, String)] = [
            (
                "AudioEncoder.mlmodelc/analytics/coremldata.bin", .otherData, 243,
                "c4e096b2abd561f00b9b698401df3fbe1a0d0c8d2476ff19cb4e1995680e827e"
            ),
            (
                "AudioEncoder.mlmodelc/coremldata.bin", .otherData, 347,
                "e316980638e2099e83cb1a93b903717dc12b3c2168d0ab69113764c3767696ba"
            ),
            (
                "AudioEncoder.mlmodelc/metadata.json", .otherData, 1_863,
                "d6785fae31c3f86d60058c14c79902f716f106dd9e36af7d3fe78b9c34867fce"
            ),
            (
                "AudioEncoder.mlmodelc/model.mil", .otherData, 579_125,
                "dc74813e26fce790fe22a33dcef8be535b9dce566f38a8bdb677f5e07dcf9138"
            ),
            (
                "AudioEncoder.mlmodelc/model.mlmodel", .otherData, 79_853,
                "1d42038f84b508da5ce9b953302387ffedc097c346d36a56b765109002b6080e"
            ),
            (
                "AudioEncoder.mlmodelc/weights/weight.bin", .weights, 41_189_632,
                "061ff4d74e5de3937b31288465d6c6f2697f92d121c80b23f51dd26bbdfe642b"
            ),
            (
                "MelSpectrogram.mlmodelc/analytics/coremldata.bin", .otherData, 243,
                "7f77e6457285248f99cd7aa3fd4cc2efbb17733e63e7023ac53abe1f95785d07"
            ),
            (
                "MelSpectrogram.mlmodelc/coremldata.bin", .otherData, 328,
                "dabdc5aa69f6ef4d97dc9499f5c30514e00e96b53b750b33a5a6471363c71662"
            ),
            (
                "MelSpectrogram.mlmodelc/metadata.json", .otherData, 1_848,
                "f2b08d80d9cdd39fc0ccdbb5fac86a5f8dd9bcaa839706c3568be6fe8abd82d4"
            ),
            (
                "MelSpectrogram.mlmodelc/model.mil", .otherData, 10_176,
                "b8063d8e57c113472ac7c2d248e44383568a018978a753c1884ac406b997a374"
            ),
            (
                "MelSpectrogram.mlmodelc/weights/weight.bin", .audioModel, 354_080,
                "35d74417ef9c765e70f4ef85fe7405015a7086e9af05e3b63a5c2c7c748b2efc"
            ),
            (
                "TextDecoder.mlmodelc/analytics/coremldata.bin", .otherData, 243,
                "6ac1227740ecc2fd7a03df50ac6e2a7f7946acfa77069cf2c486ae0255356b95"
            ),
            (
                "TextDecoder.mlmodelc/coremldata.bin", .otherData, 633,
                "9f1f6fe409486e2797d3f0c65d9a6d5af596771760548cd86f41939c54cdbe7c"
            ),
            (
                "TextDecoder.mlmodelc/metadata.json", .otherData, 4_753,
                "0a64b3686b9a4b2eff0792e7df3cfe1b20467ec5d5ac52c0e01c3dbf6697b65d"
            ),
            (
                "TextDecoder.mlmodelc/model.mil", .otherData, 205_217,
                "45b9e61a0f286cddcad96e2c890c7a68460adcaa3319c4907ee4f962dfeb2c8b"
            ),
            (
                "TextDecoder.mlmodelc/model.mlmodel", .otherData, 164_481,
                "ae260ff7b95d0c957c3c1f4df4dbeaa0ae6c76bacc55eb86caca8f6820d346f0"
            ),
            (
                "TextDecoder.mlmodelc/weights/weight.bin", .otherData, 104_122_162,
                "72325d42a4a4ccc8a6fa974ede6cdf2e0770685a5c4f9da94f41495b94d8d174"
            ),
            (
                "config.json", .runtimeConfiguration, 1_464,
                "67e25477d03bf3a1c34bfd137724beed94b5218d0457e8c1d25f70379a61d9d5"
            ),
            (
                "generation_config.json", .otherData, 2_762,
                "662a99e3db3067708549d04d5f141910eb455f0935aed0c9b06d707f44bfbcaf"
            ),
        ]
        let base =
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/"
            + whisperRevision + "/openai_whisper-base/"
        return try values.map { value in
            try declaration(
                path: value.0,
                role: value.1,
                bytes: value.2,
                digest: value.3,
                source: base + value.0 + "?download=true"
            )
        }
    }
    // swiftlint:enable large_tuple function_body_length

    // Keep signed file hashes beside names so catalog review remains auditable.
    // swiftlint:disable function_body_length
    static func whisperTokenizerDeclarations() throws -> [Declaration] {
        let values: [(String, UInt64, String)] = [
            (
                "added_tokens.json", 34_604,
                "9715fd2243b6f06a5858b5e32950d2853f73dd5bc201aafcf76f5082a2d8acd1"
            ),
            (
                "merges.txt", 493_869,
                "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6"
            ),
            (
                "normalizer.json", 52_666,
                "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd"
            ),
            (
                "special_tokens_map.json", 2_194,
                "e67ae3a0aaa99abcd9f187138e12db1f65c16a14761c50ef10eef2c174a7a691"
            ),
            (
                "tokenizer.json", 2_480_466,
                "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566"
            ),
            (
                "tokenizer_config.json", 282_683,
                "2a4c4281cf9f51ac6ccc406fdc711a087afe6530f671fa7b80953edc498275ce"
            ),
            (
                "vocab.json", 835_550,
                "8f680bba319e01a653d2e8a5dbc17a9157179e0576e6ce74ce0c06356c6e24f9"
            ),
        ]
        let base =
            "https://huggingface.co/openai/whisper-base/resolve/"
            + whisperTokenizerRevision + "/"
        return try values.map { value in
            try declaration(
                path: value.0,
                role: value.0 == "tokenizer.json" ? .tokenizer : .otherData,
                bytes: value.1,
                digest: value.2,
                source: base + value.0 + "?download=true"
            )
        }
    }
    // swiftlint:enable function_body_length

    static func supportedOperatingSystems() -> [MinimumOperatingSystem] {
        [
            MinimumOperatingSystem(operatingSystem: .iOS, version: "18.0"),
            MinimumOperatingSystem(operatingSystem: .iPadOS, version: "18.0"),
            MinimumOperatingSystem(operatingSystem: .macOS, version: "15.0"),
        ]
    }

    static func declaration(
        path: String,
        role: ModelManifestFileRole,
        bytes: UInt64,
        digest: String,
        source: String
    ) throws -> Declaration {
        let digest = try ModelContentDigest(bytes: hex(digest))
        return Declaration(
            manifest: try ModelManifestFile(
                relativePath: path,
                role: role,
                byteCount: bytes,
                sha256: digest
            ),
            download: try ModelDownloadFile(
                relativePath: path,
                url: try url(source),
                byteCount: bytes,
                sha256: digest
            )
        )
    }

    static func hex(_ value: String) throws -> Data {
        var data = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else {
                throw InferPeerStarterCatalogError.invalidEmbeddedMetadata
            }
            data.append(byte)
            index = end
        }
        return data
    }

    static func identifier<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        _ value: String
    ) throws -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            throw InferPeerStarterCatalogError.invalidEmbeddedMetadata
        }
        return identifier
    }

    static func url(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw InferPeerStarterCatalogError.invalidEmbeddedMetadata
        }
        return url
    }
}
// swiftlint:enable file_length

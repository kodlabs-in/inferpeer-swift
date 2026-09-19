/// Stable native llama.cpp adapter failures.
public enum LlamaAdapterError: Error, Equatable, Sendable {
    case invalidManifest
    case missingArtifact
    case memoryLimitExceeded
    case nativeLoadFailed(String)
    case nativeGenerationFailed(String)
    case projectorRejected
    case sessionUnavailable
    case unsupportedQuery
}

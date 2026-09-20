/// Structural errors rejected before files can be staged or registered.
public enum ModelManifestValidationError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(UInt32)
    case invalidTextField(String)
    case invalidRelativePath(String)
    case invalidFileSize(String)
    case duplicateFilePath
    case duplicateTaskCapability
    case invalidTaskLimits(InferenceTask)
    case invalidDeviceProfile
    case missingFileRole(ModelManifestFileRole)
}

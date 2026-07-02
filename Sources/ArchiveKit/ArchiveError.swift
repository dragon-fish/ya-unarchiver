import Foundation

public enum ArchiveError: Error, Equatable {
    case needsPassword
    case wrongPassword
    case corrupted(String)
    case binaryNotFound
    case executionFailed(code: Int32, message: String)
    case invalidDestination(String)
}

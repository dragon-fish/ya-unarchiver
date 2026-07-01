import Foundation

public struct ArchiveEntry: Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let packedSize: Int64
    public let modified: Date?
    public let isDirectory: Bool
    public let isEncrypted: Bool

    public init(path: String, size: Int64, packedSize: Int64,
                modified: Date?, isDirectory: Bool, isEncrypted: Bool) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }
}

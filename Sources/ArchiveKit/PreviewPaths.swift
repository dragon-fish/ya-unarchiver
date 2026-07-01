import Foundation

/// Resolves where a single entry lands after `7zz x -o<tempBase>` extraction.
/// `7zz x` preserves the archive-internal path, so the file appears at
/// tempBase/<entryPath>.
public enum PreviewPaths {
    public static func fileURL(tempBase: URL, entryPath: String) -> URL {
        tempBase.appendingPathComponent(entryPath)
    }
}

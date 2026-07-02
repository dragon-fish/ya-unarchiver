import Foundation

public enum ExtractionTarget {

    public static func archiveBaseName(_ archive: URL) -> String {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] {
            if lower.hasSuffix(double) {
                return String(name.dropLast(double.count))
            }
        }
        return (name as NSString).deletingPathExtension
    }

    /// Returns the single top-level directory name, or nil.
    public static func hasSingleTopLevelDirectory(_ entries: [ArchiveEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var topComponents = Set<String>()
        for e in entries {
            let first = e.path.split(separator: "/").first.map(String.init) ?? e.path
            topComponents.insert(first)
        }
        guard topComponents.count == 1, let top = topComponents.first else { return nil }

        // The single top component must be a directory: either it has children
        // (some entry path contains "/") or an explicit dir entry says so.
        let hasChildren = entries.contains { $0.path.contains("/") }
        let explicitDir = entries.first { $0.path == top }?.isDirectory ?? false
        return (hasChildren || explicitDir) ? top : nil
    }

    public static func resolve(
        archive: URL,
        entries: [ArchiveEntry],
        directoryExists: (URL) -> Bool
    ) -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = hasSingleTopLevelDirectory(entries) ?? archiveBaseName(archive)

        var candidate = parent.appendingPathComponent(baseName)
        var counter = 2
        while directoryExists(candidate) {
            candidate = parent.appendingPathComponent("\(baseName) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// Appends " 2", " 3", … to `base`'s last path component until it doesn't exist.
    public static func numbered(base: URL, directoryExists: (URL) -> Bool) -> URL {
        guard directoryExists(base) else { return base }
        let parent = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        var counter = 2
        var candidate = parent.appendingPathComponent("\(name) \(counter)")
        while directoryExists(candidate) {
            counter += 1
            candidate = parent.appendingPathComponent("\(name) \(counter)")
        }
        return candidate
    }
}

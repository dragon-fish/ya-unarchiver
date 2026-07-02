import Foundation

/// Computes how many entries 7zz will emit an output line for during extraction,
/// used as the denominator for a real progress bar. Counting is by entry (files
/// and directories alike), matching `7zz x -bb1`, which logs one line per extracted
/// entry.
public enum ExtractionProgress {
    /// - Parameters:
    ///   - entries: the full archive listing.
    ///   - selectedPaths: nil extracts everything; otherwise only these archive-internal
    ///     paths and everything beneath them.
    /// - Returns: the number of entries that will be extracted. For a selection, an entry
    ///   counts when its path equals a selected path or is nested under it (prefix
    ///   `"<selected>/"`), so selecting `a` does not match a sibling `ab`.
    public static func totalEntryCount(entries: [ArchiveEntry], selectedPaths: [String]?) -> Int {
        guard let selectedPaths else { return entries.count }
        let selected = Set(selectedPaths)
        return entries.filter { entry in
            if selected.contains(entry.path) { return true }
            return selectedPaths.contains { entry.path.hasPrefix($0 + "/") }
        }.count
    }
}

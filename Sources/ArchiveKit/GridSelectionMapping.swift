import Foundation

/// Pure, UI-agnostic mapping between row indices and `ArchiveNode` ids, used by
/// the icon grid to sync `NSCollectionView`'s index-based selection with the
/// SwiftUI `Set<ArchiveNode.ID>` binding. Mirrors the `Breadcrumb` helper pattern:
/// navigation/selection logic that is testable without any AppKit/SwiftUI surface.
public enum GridSelectionMapping {
    /// Row indices → the set of node ids at those rows. Out-of-range rows are ignored.
    public static func ids(forRows rows: [Int], in nodes: [ArchiveNode]) -> Set<ArchiveNode.ID> {
        var result: Set<ArchiveNode.ID> = []
        for row in rows where row >= 0 && row < nodes.count {
            result.insert(nodes[row].id)
        }
        return result
    }

    /// Node ids → the row indices holding them, ascending. Ids absent from `nodes` are dropped.
    public static func rows(forIDs ids: Set<ArchiveNode.ID>, in nodes: [ArchiveNode]) -> [Int] {
        var result: [Int] = []
        for (row, node) in nodes.enumerated() where ids.contains(node.id) {
            result.append(row)
        }
        return result
    }
}

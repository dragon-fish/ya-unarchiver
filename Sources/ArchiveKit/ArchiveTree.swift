import Foundation

public final class ArchiveNode: Identifiable {
    public let id: String          // full path, "" for root
    public let name: String
    public let isDirectory: Bool
    public internal(set) var entry: ArchiveEntry?
    public internal(set) var children: [ArchiveNode]

    init(id: String, name: String, isDirectory: Bool, entry: ArchiveEntry?) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.entry = entry
        self.children = []
    }
}

public enum ArchiveTree {
    public static func build(from entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(id: "", name: "", isDirectory: true, entry: nil)
        var nodesByPath: [String: ArchiveNode] = ["": root]

        // Deterministic order so intermediate dirs form before leaves.
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var currentPath = ""
            var parent = root
            for (index, comp) in components.enumerated() {
                let isLast = index == components.count - 1
                let childPath = currentPath.isEmpty ? comp : currentPath + "/" + comp
                if let existing = nodesByPath[childPath] {
                    if isLast { existing.entry = entry }  // attach explicit entry
                    parent = existing
                } else {
                    let dir = isLast ? entry.isDirectory : true
                    let node = ArchiveNode(
                        id: childPath, name: comp, isDirectory: dir,
                        entry: isLast ? entry : nil
                    )
                    parent.children.append(node)
                    nodesByPath[childPath] = node
                    parent = node
                }
                currentPath = childPath
            }
        }
        return root
    }
}

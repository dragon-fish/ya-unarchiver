import SwiftUI
import ArchiveKit

struct TwoPaneBrowserView: BrowserLayout {
    let root: ArchiveNode
    @Binding var selection: ArchiveNode.ID?

    init(root: ArchiveNode, selection: Binding<ArchiveNode.ID?>) {
        self.root = root
        self._selection = selection
    }

    private var directorySubtree: [ArchiveNode] { root.children.filter(\.isDirectory) }

    private var selectedNode: ArchiveNode? {
        guard let selection else { return root }
        return Self.find(id: selection, in: root)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                OutlineGroup(directorySubtree, id: \.id, children: \.directoryChildrenOrNil) { node in
                    Label(node.name, systemImage: "folder")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            Table(selectedNode?.children ?? []) {
                TableColumn("名称") { (n: ArchiveNode) in
                    Label(n.name, systemImage: n.isDirectory ? "folder" : "doc")
                }
                TableColumn("大小") { n in Text(n.isDirectory ? "—" : Self.byteString(n.entry?.size)) }
                TableColumn("压缩后") { n in Text(n.isDirectory ? "—" : Self.byteString(n.entry?.packedSize)) }
                TableColumn("修改日期") { n in Text(Self.dateString(n.entry?.modified)) }
            }
        }
    }

    private static func find(id: ArchiveNode.ID, in node: ArchiveNode) -> ArchiveNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    private static func byteString(_ v: Int64?) -> String {
        guard let v else { return "—" }
        return ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    private static func dateString(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}

private extension ArchiveNode {
    /// OutlineGroup wants nil for leaves; return only directory children.
    var directoryChildrenOrNil: [ArchiveNode]? {
        let dirs = children.filter(\.isDirectory)
        return dirs.isEmpty ? nil : dirs
    }
}

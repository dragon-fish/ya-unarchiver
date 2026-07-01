import SwiftUI
import ArchiveKit

struct TwoPaneBrowserView: BrowserLayout {
    let root: ArchiveNode
    @Binding var selection: Set<ArchiveNode.ID>
    let previewService: PreviewService
    let onExtractSelected: (Set<ArchiveNode.ID>) -> Void

    /// The folder whose contents the right pane shows. "" is the archive root.
    @State private var currentDirectoryID: ArchiveNode.ID = ""

    init(root: ArchiveNode,
         selection: Binding<Set<ArchiveNode.ID>>,
         previewService: PreviewService,
         onExtractSelected: @escaping (Set<ArchiveNode.ID>) -> Void) {
        self.root = root
        self._selection = selection
        self.previewService = previewService
        self.onExtractSelected = onExtractSelected
    }

    private var directorySubtree: [ArchiveNode] { root.children.filter(\.isDirectory) }

    private var currentDirectory: ArchiveNode {
        Self.find(id: currentDirectoryID, in: root) ?? root
    }

    /// Bridges the directory-only sidebar selection to `currentDirectoryID`.
    private var sidebarSelection: Binding<ArchiveNode.ID?> {
        Binding(
            get: { currentDirectoryID.isEmpty ? nil : currentDirectoryID },
            set: { if let id = $0 { currentDirectoryID = id } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                OutlineGroup(directorySubtree, id: \.id, children: \.directoryChildrenOrNil) { node in
                    Label(node.name, systemImage: "folder")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                breadcrumbBar
                Divider()
                fileTable
            }
        }
        .onChange(of: currentDirectoryID) { _, _ in selection = [] }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button { navigateToParent() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(currentDirectoryID.isEmpty)
            Button("根目录") { currentDirectoryID = "" }
                .buttonStyle(.link)
            ForEach(Breadcrumb.segments(forPath: currentDirectoryID), id: \.id) { segment in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(segment.name) { currentDirectoryID = segment.id }
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var fileTable: some View {
        Table(currentDirectory.children, selection: $selection) {
            TableColumn("名称") { (n: ArchiveNode) in
                Label(n.name, systemImage: n.isDirectory ? "folder" : "doc")
            }
            TableColumn("大小") { n in Text(n.isDirectory ? "—" : Self.byteString(n.entry?.size)) }
            TableColumn("压缩后") { n in Text(n.isDirectory ? "—" : Self.byteString(n.entry?.packedSize)) }
            TableColumn("修改日期") { n in Text(Self.dateString(n.entry?.modified)) }
        }
        .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            handlePrimaryAction(ids)
        }
    }

    // MARK: - Navigation

    private func navigateToParent() {
        guard !currentDirectoryID.isEmpty else { return }
        currentDirectoryID = currentDirectoryID.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func handlePrimaryAction(_ ids: Set<ArchiveNode.ID>) {
        guard ids.count == 1, let id = ids.first,
              let node = Self.find(id: id, in: root) else { return }
        if node.isDirectory {
            currentDirectoryID = node.id
        }
        // File open/preview added in the next task.
    }

    // MARK: - Context menu (populated in the next task)

    @ViewBuilder
    private func contextMenu(for ids: Set<ArchiveNode.ID>) -> some View {
        Button("解压选中…") { onExtractSelected(ids) }
            .disabled(ids.isEmpty)
    }

    // MARK: - Helpers

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

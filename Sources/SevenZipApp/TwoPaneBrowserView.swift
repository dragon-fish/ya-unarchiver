import SwiftUI
import QuickLook
import AppKit
import UniformTypeIdentifiers
import ArchiveKit

struct TwoPaneBrowserView: BrowserLayout {
    let root: ArchiveNode
    @Binding var selection: Set<ArchiveNode.ID>
    let previewService: PreviewService
    let onExtractSelected: (Set<ArchiveNode.ID>) -> Void

    /// The folder whose contents the right pane shows. "" is the archive root.
    @State private var currentDirectoryID: ArchiveNode.ID = ""

    /// Non-nil while a file is shown in the QuickLook panel.
    @State private var previewURL: URL?

    /// Path-bar folder icon size, tied to the `.callout` text metric (not a raw
    /// literal) so it tracks the system text size.
    @ScaledMetric(relativeTo: .callout) private var pathIconSize: CGFloat = 16

    init(root: ArchiveNode,
         selection: Binding<Set<ArchiveNode.ID>>,
         previewService: PreviewService,
         onExtractSelected: @escaping (Set<ArchiveNode.ID>) -> Void) {
        self.root = root
        self._selection = selection
        self.previewService = previewService
        self.onExtractSelected = onExtractSelected
    }

    /// Sidebar directory ids currently expanded; auto-populated when navigating
    /// so the tree reveals the folder you double-click into on the right.
    @State private var expandedDirs: Set<ArchiveNode.ID> = []

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
                SidebarTree(nodes: root.children, expanded: $expandedDirs)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                fileTable
                Divider()
                pathBar
            }
        }
        .onChange(of: currentDirectoryID) { _, newID in
            selection = []
            // Reveal the current folder in the sidebar by expanding its ancestors.
            for segment in Breadcrumb.segments(forPath: newID) {
                expandedDirs.insert(segment.id)
            }
        }
        .quickLookPreview($previewURL)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { navigateToParent() } label: {
                    Image(systemName: "arrowshape.turn.up.backward")
                }
                .disabled(currentDirectoryID.isEmpty)
                .help("返回上一层")
            }
        }
    }

    /// Finder-style path bar at the bottom of the file list: folder icon + name
    /// segments separated by chevrons, click a segment to navigate there.
    private var pathBar: some View {
        HStack(spacing: 2) {
            pathSegment(name: previewService.archiveURL.lastPathComponent, id: "")
            ForEach(Breadcrumb.segments(forPath: currentDirectoryID), id: \.id) { segment in
                Image(systemName: "chevron.right")
                    .font(.callout)          // same text style as segments…
                    .imageScale(.small)      // …rendered a size smaller, like Finder
                    .foregroundStyle(.tertiary)
                pathSegment(name: segment.name, id: segment.id)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)          // match Finder's path-bar height
        .background(.bar)
    }

    private func pathSegment(name: String, id: ArchiveNode.ID) -> some View {
        Button { currentDirectoryID = id } label: {
            HStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: pathIconSize, height: pathIconSize)
                Text(name).font(.callout)
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)   // fill the bar height so the whole segment is clickable
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// Right-pane rows: folders first, then files, each in Finder-style
    /// natural name order.
    private var sortedChildren: [ArchiveNode] {
        currentDirectory.children.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var fileTable: some View {
        // Drag-out is attached at the ROW level via `.itemProvider`, not on the name
        // cell. A cell-level `.onDrag` turns that region into a drag source that
        // swallows the click, so the icon+name area couldn't select or double-open.
        // Row-level itemProvider coexists with Table selection and primaryAction.
        Table(of: ArchiveNode.self, selection: $selection) {
            TableColumn("名称") { (n: ArchiveNode) in
                HStack(spacing: 6) {
                    Image(nsImage: Self.icon(for: n))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(n.name)
                }
            }
            TableColumn("大小") { n in Text(n.isDirectory ? "—" : Self.byteString(n.entry?.size)) }
            TableColumn("压缩后") { n in Text(n.isDirectory ? "—" : Self.byteString(n.entry?.packedSize)) }
            TableColumn("修改日期") { n in Text(Self.dateString(n.entry?.modified)) }
        } rows: {
            ForEach(sortedChildren) { n in
                TableRow(n)
                    .itemProvider { makeDragProvider(n) }
            }
        }
        .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            handlePrimaryAction(ids)
        }
        .onKeyPress(.space) {
            guard let file = singleSelectedFile else { return .ignored }
            Task { previewURL = try? await previewService.url(for: file) }
            return .handled
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
        } else {
            Task { await previewService.open(node) }
        }
    }

    // MARK: - Context menu (populated in the next task)

    @ViewBuilder
    private func contextMenu(for ids: Set<ArchiveNode.ID>) -> some View {
        if ids.count == 1, let id = ids.first,
           let node = Self.find(id: id, in: root), !node.isDirectory {
            Button("用默认程序打开") { Task { await previewService.open(node) } }
            Button("快速查看") { Task { previewURL = try? await previewService.url(for: node) } }
            Divider()
        }
        Button("解压选中…") { onExtractSelected(ids) }
            .disabled(ids.isEmpty)
    }

    // MARK: - Helpers

    /// The selected node when exactly one file (not a directory) is selected.
    private var singleSelectedFile: ArchiveNode? {
        guard selection.count == 1, let id = selection.first,
              let node = Self.find(id: id, in: root), !node.isDirectory else { return nil }
        return node
    }

    // MARK: - Drag out to Finder

    /// Builds a lazy file-promise provider: Finder only triggers extraction when the
    /// user actually drops. Reuses PreviewService's on-demand extraction + per-window
    /// temp dir + cache. A file extracts to a single file; a directory extracts its
    /// whole subtree. Finder lands the item by its leaf name, so there is no prefix issue.
    private func makeDragProvider(_ node: ArchiveNode) -> NSItemProvider {
        let provider = NSItemProvider()
        let type: UTType = node.isDirectory
            ? .folder
            : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
        provider.suggestedName = node.name
        let previewService = self.previewService
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                             fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let url = try await previewService.url(for: node)
                    completion(url, false, nil)   // false = coordinated copy, keep our temp file
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private static func find(id: ArchiveNode.ID, in node: ArchiveNode) -> ArchiveNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    /// System (Finder) icon for a node, resolved by UTI: real folder icon for
    /// directories, the type's associated icon (by file extension) for files.
    private static func icon(for node: ArchiveNode) -> NSImage {
        let type: UTType
        if node.isDirectory {
            type = .folder
        } else {
            let ext = (node.name as NSString).pathExtension
            type = UTType(filenameExtension: ext) ?? .data
        }
        return NSWorkspace.shared.icon(for: type)
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

/// Recursive directory-only sidebar with externally controlled expansion, so
/// navigation on the right can programmatically expand the tree to the current
/// folder. Each row is tagged with its node id to drive the List selection.
private struct SidebarTree: View {
    let nodes: [ArchiveNode]
    @Binding var expanded: Set<ArchiveNode.ID>

    var body: some View {
        ForEach(directories) { node in
            if node.children.contains(where: \.isDirectory) {
                DisclosureGroup(isExpanded: binding(node.id)) {
                    SidebarTree(nodes: node.children, expanded: $expanded)
                } label: {
                    Label(node.name, systemImage: "folder").tag(node.id)
                }
            } else {
                Label(node.name, systemImage: "folder").tag(node.id)
            }
        }
    }

    private var directories: [ArchiveNode] {
        nodes.filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func binding(_ id: ArchiveNode.ID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }
}

// MARK: - Xcode Preview

// PreviewProvider (not the #Preview macro) is used deliberately: the macro needs
// Xcode's macro plugin, which the command-line `swift build` toolchain lacks.
// This form compiles under both, and Xcode's canvas still shows it live.
struct TwoPaneBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        TwoPaneBrowserPreview()
    }
}

/// Live-preview wrapper: a sample directory tree + a placeholder PreviewService
/// (never actually invokes 7zz), so the layout can be iterated in Xcode's canvas.
private struct TwoPaneBrowserPreview: View {
    var body: some View {
        let entries: [ArchiveEntry] = [
            .init(path: "readme.md", size: 2048, packedSize: 900, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "images", size: 0, packedSize: 0, modified: nil, isDirectory: true, isEncrypted: false),
            .init(path: "images/logo.png", size: 34567, packedSize: 30120, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "images/icons", size: 0, packedSize: 0, modified: nil, isDirectory: true, isEncrypted: false),
            .init(path: "images/icons/star.svg", size: 1234, packedSize: 800, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "src", size: 0, packedSize: 0, modified: nil, isDirectory: true, isEncrypted: false),
            .init(path: "src/main.swift", size: 5000, packedSize: 2100, modified: nil, isDirectory: false, isEncrypted: false),
        ]
        let service = PreviewService(
            archiveURL: URL(fileURLWithPath: "/tmp/Sample.zip"),
            runner: SevenZipRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        )
        return TwoPaneBrowserView(
            root: ArchiveTree.build(from: entries),
            selection: .constant([]),
            previewService: service,
            onExtractSelected: { _ in }
        )
        .frame(width: 820, height: 520)
    }
}

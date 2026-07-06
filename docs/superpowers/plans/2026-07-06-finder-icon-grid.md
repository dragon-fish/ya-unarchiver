# Finder 式图标网格（NSCollectionView 重做）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把浏览器图标模式从 SwiftUI `LazyVGrid` 换成 `NSViewRepresentable` 包的 `NSCollectionView`,复刻完整 Finder 图标视图交互(橡皮筋框选、⇧范围选、方向键、双击、右键自动选中、拖出、空格 QuickLook)。

**Architecture:** 新增 ArchiveKit 纯映射工具(行索引↔id,可单测)与 app 层 `BrowserIconGrid.swift`(`IconGridView`/`Coordinator`/`IconGridItem`/`KeyCapturingCollectionView`);`TwoPaneBrowserView` 删掉 LazyVGrid 专属成员,`case .icon:` 改接 `IconGridView`,其余(切换/持久化/列表/helper)不动。

**Tech Stack:** Swift 6, SwiftUI + AppKit(`NSCollectionView`/`NSViewRepresentable`/`NSFilePromiseProvider`), XcodeGen + xcodebuild(`make build`), XCTest(`swift test`)。

## Global Constraints

- 部署 macOS 14.0,`SWIFT_VERSION 6.0`。面向用户文案:简体中文硬编码。
- 新增 **app-target** 源文件(`Sources/SevenZipApp/*.swift`)→ `make build` 前**必须** `xcodegen generate`。新增 **ArchiveKit** 源文件与测试文件走 SPM 自动 glob,**无需** regen。
- 图标尺寸固定 48pt;系统类型图标(复用现有 `Self.icon(for:)`),不做缩略图/尺寸滑块/拖入(YAGNI)。
- QuickLook 复用现有 `previewURL` + `.quickLookPreview`,不引入 `QLPreviewPanel`。
- 右键菜单动作与列表模式**共用同一批语义**(打开/快速查看/解压选中)。
- `BrowserLayout` 协议不动。在 `feat/browser-view-modes` 分支;不在 master 提交。
- Commit:英文 Conventional Commits;每个 Task 末尾 commit 一次。
- ArchiveKit 测试跑法:`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite>`(xcode-select 指向 CommandLineTools,缺 XCTest,故 DEVELOPER_DIR 前缀必需)。

---

### Task 1: `GridSelectionMapping` 纯映射 + 单测(ArchiveKit)

**Files:**
- Create: `Sources/ArchiveKit/GridSelectionMapping.swift`
- Test: `Tests/ArchiveKitTests/GridSelectionMappingTests.swift`

**Interfaces:**
- Consumes(既有):`ArchiveNode`(`id: String`)、`ArchiveEntry`、`ArchiveTree.build(from:)`。
- Produces(供 Task 2 Coordinator):`GridSelectionMapping.ids(forRows:in:) -> Set<ArchiveNode.ID>`、`GridSelectionMapping.rows(forIDs:in:) -> [Int]`。

- [ ] **Step 1: 写失败测试**

`Tests/ArchiveKitTests/GridSelectionMappingTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class GridSelectionMappingTests: XCTestCase {
    // Top-level children in a known, deterministic order (ArchiveTree sorts entries by path).
    private func sampleNodes() -> [ArchiveNode] {
        let entries: [ArchiveEntry] = [
            .init(path: "a.txt", size: 1, packedSize: 1, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "b.txt", size: 1, packedSize: 1, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "c.txt", size: 1, packedSize: 1, modified: nil, isDirectory: false, isEncrypted: false),
        ]
        return ArchiveTree.build(from: entries).children
    }

    func testIdsForRowsBasic() {
        let nodes = sampleNodes()
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [0], in: nodes), [nodes[0].id])
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [0, 2], in: nodes), [nodes[0].id, nodes[2].id])
    }

    func testIdsForRowsEmpty() {
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [], in: sampleNodes()), [])
    }

    func testIdsForRowsOutOfRangeIgnored() {
        let nodes = sampleNodes()
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [-1, 1, 99], in: nodes), [nodes[1].id])
    }

    func testRowsForIdsSortedAscending() {
        let nodes = sampleNodes()
        let ids: Set<ArchiveNode.ID> = [nodes[2].id, nodes[0].id]
        XCTAssertEqual(GridSelectionMapping.rows(forIDs: ids, in: nodes), [0, 2])
    }

    func testRowsForIdsUnknownDropped() {
        let nodes = sampleNodes()
        XCTAssertEqual(GridSelectionMapping.rows(forIDs: ["does/not/exist"], in: nodes), [])
    }

    func testRoundTrip() {
        let nodes = sampleNodes()
        let rows = [0, 2]
        let ids = GridSelectionMapping.ids(forRows: rows, in: nodes)
        XCTAssertEqual(GridSelectionMapping.rows(forIDs: ids, in: nodes), rows)
    }
}
```

- [ ] **Step 2: 运行,确认失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GridSelectionMapping`
Expected: 编译失败/FAIL(`GridSelectionMapping` 未定义)。

- [ ] **Step 3: 写实现**

`Sources/ArchiveKit/GridSelectionMapping.swift`:

```swift
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
```

- [ ] **Step 4: 运行,确认通过**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GridSelectionMapping`
Expected: PASS(6 tests)。

- [ ] **Step 5: Commit**

```bash
git add Sources/ArchiveKit/GridSelectionMapping.swift Tests/ArchiveKitTests/GridSelectionMappingTests.swift
git commit -m "feat(archivekit): grid row↔id selection mapping with tests"
```

---

### Task 2: `IconGridView` 骨架 — 显示 + 选择双向同步 + 空格 QuickLook + 接线

**Files:**
- Create: `Sources/SevenZipApp/BrowserIconGrid.swift`
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`

**Interfaces:**
- Consumes:`GridSelectionMapping`(Task 1);既有 `ArchiveNode`、`PreviewService`(`@MainActor`,`url(for:) async throws -> URL`)、`TwoPaneBrowserView` 的 `sortedChildren`/`selection`/`singleSelectedFile`/`previewURL`/`previewService`/`handlePrimaryAction(_:)`/`Self.icon(for:)`。
- Produces(供 Task 3/4):`IconGridView`(struct)、`IconGridView.Coordinator`、`IconGridItem`、`KeyCapturingCollectionView`。

**说明:** 本 Task 交付「图标模式能显示,且单击/⌘/⇧/橡皮筋/方向键选择与 `selection` 双向同步,空格 QuickLook 生效」。双击打开、右键菜单、拖出留待 Task 3/4。

- [ ] **Step 1: 新建 `BrowserIconGrid.swift`(视图/单元/子类/协调器)**

`Sources/SevenZipApp/BrowserIconGrid.swift`:

```swift
import SwiftUI
import AppKit
import ArchiveKit

/// AppKit-backed large-icon grid: a Finder-style alternative to the SwiftUI
/// `Table`, wrapping `NSCollectionView` so selection (rubber-band, ⇧-range,
/// arrow keys), space-QuickLook, double-click, right-click and drag-out all
/// come from the native control instead of hand-rolled gestures.
struct IconGridView: NSViewRepresentable {
    let nodes: [ArchiveNode]
    @Binding var selection: Set<ArchiveNode.ID>
    let previewService: PreviewService
    let iconProvider: (ArchiveNode) -> NSImage
    /// Double-click / Return on a single item (folder → enter, file → open).
    let onPrimaryAction: (ArchiveNode.ID) -> Void
    /// Space on a single selected file → QuickLook (reuses the list-mode path).
    let onQuickLook: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 88, height: 84)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let cv = KeyCapturingCollectionView()
        cv.collectionViewLayout = layout
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.register(IconGridItem.self, forItemWithIdentifier: IconGridItem.identifier)
        cv.onQuickLook = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onQuickLook()
        }

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let cv = scrollView.documentView as? NSCollectionView else { return }
        context.coordinator.parent = self

        // Reload only when the node set (ids/order) actually changed.
        let newIDs = nodes.map(\.id)
        if context.coordinator.currentIDs != newIDs {
            context.coordinator.currentIDs = newIDs
            cv.reloadData()
        }

        // Push SwiftUI selection → collection view, diffing first so an already-in-
        // sync state is left untouched (prevents a select/deselect feedback loop).
        let desired = Set(GridSelectionMapping.rows(forIDs: selection, in: nodes)
            .map { IndexPath(item: $0, section: 0) })
        if cv.selectionIndexPaths != desired {
            cv.deselectItems(at: cv.selectionIndexPaths.subtracting(desired))
            cv.selectItems(at: desired.subtracting(cv.selectionIndexPaths), scrollPosition: [])
            // selectItems/deselectItems do NOT fire delegate callbacks, so no echo back.
        }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: IconGridView
        /// Snapshot of the ids currently loaded, to detect when a reload is needed.
        var currentIDs: [String] = []

        init(_ parent: IconGridView) { self.parent = parent }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.nodes.count
        }

        func collectionView(_ cv: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = cv.makeItem(withIdentifier: IconGridItem.identifier, for: indexPath) as! IconGridItem
            let node = parent.nodes[indexPath.item]
            item.configure(name: node.name, icon: parent.iconProvider(node))
            return item
        }

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToBinding(cv)
        }

        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToBinding(cv)
        }

        /// Collection view selection → SwiftUI binding. Guarded by an equality check
        /// so it only writes on a real change.
        private func syncSelectionToBinding(_ cv: NSCollectionView) {
            let rows = cv.selectionIndexPaths.map(\.item)
            let ids = GridSelectionMapping.ids(forRows: rows, in: parent.nodes)
            if parent.selection != ids { parent.selection = ids }
        }
    }
}

/// `NSCollectionView` subclass that intercepts the space bar for QuickLook while
/// letting arrow-key selection fall through to the native implementation.
final class KeyCapturingCollectionView: NSCollectionView {
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onQuickLook?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// One grid cell: a 48pt system icon above a centered, two-line-truncated name,
/// with an accent-tinted rounded background when selected.
final class IconGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconGridItem")

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.font = .preferredFont(forTextStyle: .callout)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        container.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
        ])
    }

    func configure(name: String, icon: NSImage) {
        iconView.image = icon
        nameLabel.stringValue = name
    }

    override var isSelected: Bool {
        didSet { updateSelectionHighlight() }
    }

    private func updateSelectionHighlight() {
        guard let layer = view.layer else { return }
        layer.cornerRadius = 8
        layer.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
    }
}
```

- [ ] **Step 2: 改 `TwoPaneBrowserView.swift` — 删 LazyVGrid 成员**

删除以下 5 段(当前约 185–236 行):`gridIconSide`、`fileGrid`、`gridCell(_:)`、`toggleSelection(_:)`、`contextTargets(_:)`。删除后 `fileTable` 计算属性之后直接是 `// MARK: - Navigation`。

被删代码(用于精确定位,全部移除):

```swift
    /// Icon side length in the grid (fixed; no size slider in v1).
    private var gridIconSide: CGFloat { 48 }

    /// Large-icon grid alternative to `fileTable`. Shares all interaction helpers.
    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                ForEach(sortedChildren) { n in
                    gridCell(n)
                }
            }
            .padding(12)
        }
    }

    private func gridCell(_ n: ArchiveNode) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: Self.icon(for: n))
                .resizable()
                .frame(width: gridIconSide, height: gridIconSide)
            Text(n.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 88)
        .padding(6)
        .background(
            selection.contains(n.id) ? Color.accentColor.opacity(0.25) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(n.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { handlePrimaryAction([n.id]) })
        .onDrag { makeDragProvider(n) }
        .contextMenu { contextMenu(for: contextTargets(n.id)) }
    }

    /// Single-click selects one; Cmd-click toggles membership (grid multi-select).
    private func toggleSelection(_ id: ArchiveNode.ID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    /// Right-click acts on the whole selection if the clicked item is in it,
    /// otherwise on just that item (Finder behaviour).
    private func contextTargets(_ id: ArchiveNode.ID) -> Set<ArchiveNode.ID> {
        selection.contains(id) ? selection : [id]
    }
```

- [ ] **Step 3: 改 `TwoPaneBrowserView.swift` — `case .icon:` 接 `IconGridView`**

`body` 的 `Group { switch viewMode { … } }` 中,把 `case .icon: fileGrid` 改为:

```swift
                    case .icon:
                        IconGridView(
                            nodes: sortedChildren,
                            selection: $selection,
                            previewService: previewService,
                            iconProvider: { Self.icon(for: $0) },
                            onPrimaryAction: { handlePrimaryAction([$0]) },
                            onQuickLook: {
                                guard let file = singleSelectedFile else { return }
                                Task { previewURL = try? await previewService.url(for: file) }
                            }
                        )
```

`case .list: fileTable` 与外层 `.onKeyPress(.space)`(挂在 `Group` 上,供列表模式)保持不动 —— 图标模式下 `NSCollectionView` 抢占键盘焦点、自行消费空格,SwiftUI 的 `onKeyPress` 不会重复触发。

- [ ] **Step 4: 生成工程 + 构建**

Run: `xcodegen generate && make build`
Expected: BUILD SUCCEEDED(新 app 文件 `BrowserIconGrid.swift` 已纳入编译)。

> 若构建报「`BrowserIconGrid.swift` 找不到符号/未编译」,确认已跑 `xcodegen generate`(新增 app 源文件必须 regen)。若报 Swift 6 并发相关(如闭包 `@Sendable`/actor 隔离),按最小改动修正——`NSViewRepresentable`/`Coordinator` 方法均为 `@MainActor`,`previewService` 亦 `@MainActor`,应无跨 actor 逃逸;修正后须保持行为不变并在报告中说明。

- [ ] **Step 5: 手动验证(图标模式基础交互)**

Run: `make run`,确认:
1. 工具栏切到图标模式,右侧显示大图标网格(48pt 图标 + 居中两行截断名称)。
2. 单击选中(高亮);⌘-单击加/减;⇧-单击范围选;在空白处拖矩形**橡皮筋框选**一片;方向键移动选中。
3. 选中单个文件按**空格** → QuickLook 预览弹出。
4. 切到列表模式再切回,`selection` 保持;进入下一层目录(此步下一 Task 才有双击,可用列表模式双击进目录再切图标)选择清空。
5. 列表模式空格预览、点击、排序无回归。

- [ ] **Step 6: Commit**

```bash
git add Sources/SevenZipApp/BrowserIconGrid.swift Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(browser): NSCollectionView icon grid with native selection + space QuickLook"
```

---

### Task 3: 双击打开 + 回车 + 右键自动选中菜单

**Files:**
- Modify: `Sources/SevenZipApp/BrowserIconGrid.swift`
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`

**Interfaces:**
- Consumes:Task 2 的 `IconGridView`/`Coordinator`/`KeyCapturingCollectionView`;既有 `onExtractSelected`、`previewService.open(_:)`、`contextMenu(for:)` 的动作语义。
- Produces:`GridMenuAction`(struct)、`IconGridView.menuActions` 字段、`TwoPaneBrowserView.gridMenuActions(_:)`。

- [ ] **Step 1: `BrowserIconGrid.swift` — 加 `GridMenuAction` + `menuActions` 字段**

在 `BrowserIconGrid.swift` 顶部 `import` 之后、`struct IconGridView` 之前加:

```swift
/// A single right-click menu entry, rendered by AppKit `NSMenu` in grid mode and
/// derived from the same source as the list-mode SwiftUI `.contextMenu`, so the two
/// never drift apart.
struct GridMenuAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}
```

在 `IconGridView` 的 `let onQuickLook: () -> Void` 之后加字段:

```swift
    /// Right-click menu for the given target ids (clicked item auto-selected first).
    let menuActions: (Set<ArchiveNode.ID>) -> [GridMenuAction]
```

- [ ] **Step 2: `BrowserIconGrid.swift` — 双击/回车打开**

在 `makeNSView` 里,`cv.onQuickLook = { … }` 之后追加双击手势与回车回调:

```swift
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false   // don't swallow single-click selection
        cv.addGestureRecognizer(doubleClick)

        cv.onReturnKey = { [weak coordinator = context.coordinator] in
            coordinator?.primaryActionOnSelection()
        }
```

在 `KeyCapturingCollectionView` 加回车支持——把它改为:

```swift
final class KeyCapturingCollectionView: NSCollectionView {
    var onQuickLook: (() -> Void)?
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ":
            onQuickLook?()
        case "\r":
            onReturnKey?()
        default:
            super.keyDown(with: event)
        }
    }
}
```

在 `Coordinator` 内加(放 `syncSelectionToBinding` 之后):

```swift
        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let cv = gesture.view as? NSCollectionView else { return }
            let point = gesture.location(in: cv)
            guard let indexPath = cv.indexPathForItem(at: point),
                  indexPath.item < parent.nodes.count else { return }
            parent.onPrimaryAction(parent.nodes[indexPath.item].id)
        }

        /// Return key opens the single selected item (matches Finder).
        func primaryActionOnSelection() {
            let rows = parent.selection.isEmpty
                ? []
                : GridSelectionMapping.rows(forIDs: parent.selection, in: parent.nodes)
            guard rows.count == 1 else { return }
            parent.onPrimaryAction(parent.nodes[rows[0]].id)
        }
```

- [ ] **Step 3: `BrowserIconGrid.swift` — 右键自动选中 + `NSMenu`**

在 `KeyCapturingCollectionView` 加右键菜单构建(它持有对 owning `IconGridView` 交互所需的回调)。给它加两个属性与 `menu(for:)` 重写:

```swift
    /// Returns the current selection ids (collection view is the source of truth).
    var currentSelectionIDs: (() -> Set<ArchiveNode.ID>)?
    /// Makes the clicked item the sole selection when it's outside the current one.
    var selectSingle: ((IndexPath) -> Void)?
    /// Builds the menu entries for a set of target ids.
    var menuActionsFor: ((Set<ArchiveNode.ID>) -> [GridMenuAction])?
    /// Maps a hit index path to its node id.
    var idForIndexPath: ((IndexPath) -> ArchiveNode.ID?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point),
              let clickedID = idForIndexPath?(indexPath) else { return nil }

        // Finder behaviour: right-clicking an item outside the selection selects just it.
        let current = currentSelectionIDs?() ?? []
        let targets: Set<ArchiveNode.ID>
        if current.contains(clickedID) {
            targets = current
        } else {
            selectSingle?(indexPath)
            targets = [clickedID]
        }

        guard let actions = menuActionsFor?(targets), !actions.isEmpty else { return nil }
        let menu = NSMenu()
        for action in actions {
            let item = NSMenuItem(title: action.title,
                                  action: #selector(GridMenuTarget.fire(_:)),
                                  keyEquivalent: "")
            item.isEnabled = action.isEnabled
            let target = GridMenuTarget(action.perform)
            item.representedObject = target
            item.target = target
            menu.addItem(item)
            objc_setAssociatedObject(menu, Unmanaged.passUnretained(item).toOpaque(),
                                     target, .OBJC_ASSOCIATION_RETAIN)
        }
        return menu
    }
```

并在文件末尾加一个小的动作转发对象(`NSMenuItem.target` 是 `weak`,故用关联对象保活):

```swift
/// Retains and fires a `GridMenuAction.perform` closure for an `NSMenuItem`.
private final class GridMenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    @objc func fire(_ sender: NSMenuItem) { action() }
}
```

在 `makeNSView` 里(创建 `cv` 后、`return scroll` 前)接线这四个回调:

```swift
        cv.idForIndexPath = { [weak coordinator = context.coordinator] indexPath in
            guard let nodes = coordinator?.parent.nodes, indexPath.item < nodes.count else { return nil }
            return nodes[indexPath.item].id
        }
        cv.currentSelectionIDs = { [weak coordinator = context.coordinator] in
            coordinator?.parent.selection ?? []
        }
        cv.selectSingle = { [weak cv, weak coordinator = context.coordinator] indexPath in
            guard let cv else { return }
            cv.deselectItems(at: cv.selectionIndexPaths)
            cv.selectItems(at: [indexPath], scrollPosition: [])
            // selectItems doesn't fire the delegate, so mirror into the binding manually.
            coordinator?.syncSelectionAfterProgrammaticChange(cv)
        }
        cv.menuActionsFor = { [weak coordinator = context.coordinator] targets in
            coordinator?.parent.menuActions(targets) ?? []
        }
```

在 `Coordinator` 加一个把「程序性改选」同步回 binding 的方法(因 `selectItems` 不回调 delegate):

```swift
        /// Mirror a programmatic selection change (e.g. right-click auto-select) into the binding.
        func syncSelectionAfterProgrammaticChange(_ cv: NSCollectionView) {
            let ids = GridSelectionMapping.ids(forRows: cv.selectionIndexPaths.map(\.item), in: parent.nodes)
            if parent.selection != ids { parent.selection = ids }
        }
```

- [ ] **Step 4: `TwoPaneBrowserView.swift` — 提供 `gridMenuActions` 并注入**

在 `IconGridView(...)` 构造里,`onQuickLook:` 闭包之后加一行:

```swift
                            menuActions: gridMenuActions
```

在 `contextMenu(for:)` 方法之后加 `gridMenuActions`(与 SwiftUI 菜单同一批动作语义):

```swift
    /// Same action set as `contextMenu(for:)` but as data, for the grid's AppKit NSMenu.
    private func gridMenuActions(_ ids: Set<ArchiveNode.ID>) -> [GridMenuAction] {
        var actions: [GridMenuAction] = []
        if ids.count == 1, let id = ids.first,
           let node = Self.find(id: id, in: root), !node.isDirectory {
            actions.append(GridMenuAction(title: "用默认程序打开", isEnabled: true) {
                Task { await previewService.open(node) }
            })
            actions.append(GridMenuAction(title: "快速查看", isEnabled: true) {
                Task { previewURL = try? await previewService.url(for: node) }
            })
        }
        actions.append(GridMenuAction(title: "解压选中…", isEnabled: !ids.isEmpty) {
            onExtractSelected(ids)
        })
        return actions
    }
```

- [ ] **Step 5: 构建**

Run: `xcodegen generate && make build`
Expected: BUILD SUCCEEDED。

> 若双击手势吞掉单击选择,或回车/右键行为异常,见计划末「偏移」；实现期可改用 `IconGridItem` 的 `mouseDown(clickCount==2)`,须保持单击选择不被破坏。

- [ ] **Step 6: 手动验证**

Run: `make run`,确认:
1. 双击文件夹进入下一层、双击文件用默认程序打开;单击选择仍正常(双击不破坏单击)。
2. 选中单个项按回车 → 同双击(进目录/开文件)。
3. 右键**已选中**项 → 菜单对整个选择;右键**未选中**项 → 该项先变为唯一选中再出菜单。
4. 菜单项:单个文件时「用默认程序打开 / 快速查看 / 解压选中…」;多选或目录时仅「解压选中…」;点击各项功能正确。

- [ ] **Step 7: Commit**

```bash
git add Sources/SevenZipApp/BrowserIconGrid.swift Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(browser): grid double-click/return open + right-click auto-select menu"
```

---

### Task 4: 拖出到 Finder(`NSFilePromiseProvider`)

**Files:**
- Modify: `Sources/SevenZipApp/BrowserIconGrid.swift`

**Interfaces:**
- Consumes:Task 2/3 的 `Coordinator`;既有 `PreviewService.url(for:) async throws -> URL`。
- Produces:图标格子拖出到 Finder 的能力(延迟提取)。

**说明:** `NSCollectionView` 拖拽要求 `NSPasteboardWriting`;用 `NSFilePromiseProvider` 承诺文件,落地时才调 `previewService.url(for:)` 惰性提取,与列表模式的 `makeDragProvider` 同一提取内核(都调 `previewService.url(for:)`)。

- [ ] **Step 1: `BrowserIconGrid.swift` — 允许拖出并提供 pasteboard writer**

在 `makeNSView` 里(创建 `cv` 后)加:

```swift
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
```

在 `Coordinator` 声明处让它额外实现 `NSFilePromiseProviderDelegate`:

```swift
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
                             NSFilePromiseProviderDelegate {
```

在 `Coordinator` 内加拖出 writer + 承诺 delegate(用后台队列写,提取时 hop 回 `@MainActor` 调 service):

```swift
        /// A dedicated queue for fulfilling file promises off the main thread.
        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.name = "IconGrid.filePromise"
            q.qualityOfService = .userInitiated
            return q
        }()

        func collectionView(_ cv: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard indexPath.item < parent.nodes.count else { return nil }
            let node = parent.nodes[indexPath.item]
            let ext = (node.name as NSString).pathExtension
            let fileType = node.isDirectory
                ? UTType.folder.identifier
                : (UTType(filenameExtension: ext) ?? .data).identifier
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
            provider.userInfo = node
            return provider
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 fileNameForType fileType: String) -> String {
            (filePromiseProvider.userInfo as? ArchiveNode)?.name ?? "item"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                 writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            guard let node = filePromiseProvider.userInfo as? ArchiveNode else {
                completionHandler(CocoaError(.fileNoSuchFile)); return
            }
            let service = parent.previewService
            Task { @MainActor in
                do {
                    let source = try await service.url(for: node)
                    try FileManager.default.copyItem(at: source, to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
```

在 `BrowserIconGrid.swift` 顶部 `import` 补上 UTType 所需:

```swift
import UniformTypeIdentifiers
```

- [ ] **Step 2: 构建**

Run: `xcodegen generate && make build`
Expected: BUILD SUCCEEDED。

> `NSFilePromiseProvider.userInfo` 存 `ArchiveNode`(class,`@unchecked Sendable`);跨 `Task @MainActor` 捕获 `node`/`service` 应无并发报错。若 Swift 6 报 `completionHandler` 非 `Sendable` 之类,按最小改动修正(如在 `@MainActor` 内直接调用),保持惰性提取语义。

- [ ] **Step 3: 手动验证**

Run: `make run`,确认:
1. 图标模式下从一个文件格子拖到 Finder 窗口/桌面 → 释放后该文件被提取落地(名称正确)。
2. 从一个文件夹格子拖出 → 整个子树提取落地。
3. 拖动过程不误触发单击选择异常;不拖动时单击/双击仍正常。
4. 列表模式拖出无回归。

- [ ] **Step 4: Commit**

```bash
git add Sources/SevenZipApp/BrowserIconGrid.swift
git commit -m "feat(browser): drag icon-grid items out to Finder via file promises"
```

---

## Self-Review

**Spec coverage:**
- §只替换 fileGrid → Task 2 Step 2/3(删 LazyVGrid 成员、case .icon 接 IconGridView)。✓
- §完整 Finder 交互:选择/橡皮筋/⇧/方向键 → Task 2(NSCollectionView 原生 + 映射);双击/回车 → Task 3;右键自动选中+菜单 → Task 3;拖出 → Task 4;空格 QuickLook → Task 2。✓
- §图标固定 48pt/系统图标/无缩略图滑块 → Task 2 `IconGridItem`(48pt,iconProvider 复用 Self.icon)。✓
- §QuickLook 复用 previewURL → Task 2 onQuickLook 闭包 = 现有逻辑。✓
- §右键菜单动作共享 → Task 3 `gridMenuActions` 与 `contextMenu(for:)` 同一批语义(GridMenuAction 数据化)。✓
- §纯映射抽 ArchiveKit 仿 Breadcrumb 单测 → Task 1。✓
- §BrowserLayout 不动、feat 分支、每 Task 一 commit → 全程遵守。✓

**Placeholder scan:** 无 TBD/TODO;每个代码步骤含完整代码。✓

**Type consistency:** `IconGridView` 字段跨 Task 增量一致(Task 2 定义 nodes/selection/previewService/iconProvider/onPrimaryAction/onQuickLook;Task 3 加 menuActions);`GridSelectionMapping.ids(forRows:in:)`/`rows(forIDs:in:)`(Task 1)在 Task 2/3 消费签名一致;`GridMenuAction`(Task 3 定义)在 `gridMenuActions` 与 `menuActionsFor` 消费一致;`previewService.url(for:)`/`open(_:)` 与实际签名(`async throws -> URL` / `async`)一致;`Self.icon(for:)`/`handlePrimaryAction(_:)`/`onExtractSelected`/`singleSelectedFile`/`previewURL` 均为主文件既有。✓

## 计划偏移 / 待同步(与用户)

1. **拖出 provider 由 Coordinator 自建(非注入闭包)**:spec 原写「注入 `dragProvider` 闭包」,实现改为 Coordinator 充当 `NSFilePromiseProviderDelegate`(delegate 是 `weak`,需长命对象持有,Coordinator 生命周期 = 视图,最稳);`IconGridView` 因此注入 `previewService` 而非 dragProvider 闭包。功能等价。
2. **双击用 `NSClickGestureRecognizer`**:`NSCollectionView` 无 `NSTableView` 那种 `doubleAction`。用 count=2 的点击手势 + `delaysPrimaryMouseButtonEvents=false` 避免吞单击。若实测仍干扰单击选择,改用 `IconGridItem.mouseDown(clickCount==2)`(Task 3 Step 5 已注明)。
3. **右键菜单目标/保活**:`NSMenuItem.target` 为 weak,故用 `GridMenuTarget` 包装 `perform` 闭包并以关联对象保活于 menu。属实现细节,不影响行为。

# 右侧文件列表交互增强 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 YA Unarchiver 右侧文件列表从纯展示做成访达式可交互面板:双击进目录(面包屑+返回)、双击文件用默认软件打开、选中按空格 QuickLook、多选驱动"解压选中"、文件行右键菜单。

**Architecture:** 纯逻辑(面包屑推导、临时文件路径解析)下沉到 ArchiveKit 加单测;新增 `PreviewService`(@MainActor)封装"单文件解压到临时目录 + 默认程序打开 + 缓存 + 清理";`TwoPaneBrowserView` 用 `currentDirectoryID` 做导航源、`Set<ArchiveNode.ID>` 做行选择,QuickLook 走 SwiftUI 原生 `.quickLookPreview`,空格走 `.onKeyPress`;`ArchiveWindow` 把选择改成多选、注入并同步 `PreviewService`。

**Tech Stack:** Swift 6 / SwiftUI(macOS 14)/ AppKit(NSWorkspace)/ Foundation / XCTest。纯 SwiftPM,无 Xcode 工程。

## Global Constraints

- **最低系统版本 macOS 14**(`Package.swift` 用 `.macOS(.v14)`,`Info.plist` 用 `14.0`)。
- **ArchiveKit 保持纯 Foundation**,不 import SwiftUI/AppKit。
- **面向用户的文案用中文**;应用名 "YA Unarchiver"。
- **测试用 `make test` 跑**(内部 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build/xctest`);裸 `swift test` 会因 CLT SDK 缺 XCTest 失败。构建用 `make build`。切勿在同一 `.build` 里混用 `make build` 与 `swift test`(会污染 module cache;真污染了就 `rm -rf .build`)。
- **每次提交 commit message 末尾加:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`,遵循 Conventional Commits。

---

## File Structure

- `Package.swift` — 平台版本(修改)。
- `Resources/Info.plist` — 最低系统版本(修改)。
- `README.md` — 系统要求 + roadmap(修改)。
- `Sources/ArchiveKit/Breadcrumb.swift` — 面包屑纯函数(新增)。
- `Sources/ArchiveKit/PreviewPaths.swift` — 临时文件路径纯函数(新增)。
- `Sources/SevenZipApp/PreviewService.swift` — 单文件解压/打开/QuickLook 后端(新增)。
- `Sources/SevenZipApp/BrowserLayout.swift` — 协议签名(修改)。
- `Sources/SevenZipApp/TwoPaneBrowserView.swift` — 导航/选择/双击/右键/QuickLook(重写)。
- `Sources/SevenZipApp/App.swift`(`ArchiveWindow`)— 多选、注入 PreviewService、密码同步、解压选中多选(修改)。
- `Tests/ArchiveKitTests/BreadcrumbTests.swift`、`PreviewPathsTests.swift` — 单测(新增)。

---

## Task 1: 抬升最低系统版本到 macOS 14

**Files:**
- Modify: `Package.swift:6`
- Modify: `Resources/Info.plist:12`
- Modify: `README.md`(Requirements 段 + roadmap 段)

**Interfaces:**
- Consumes: 无
- Produces: 工程以 macOS 14 为最低目标,后续任务可用 `.onKeyPress` / `.quickLookPreview`。

- [ ] **Step 1: 改 Package.swift 平台版本**

把 `Package.swift` 第 6 行:

```swift
    platforms: [.macOS(.v13)],
```

改为:

```swift
    platforms: [.macOS(.v14)],
```

- [ ] **Step 2: 改 Info.plist 最低版本**

把 `Resources/Info.plist` 中:

```xml
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
```

改为:

```xml
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
```

- [ ] **Step 3: 改 README 系统要求与 roadmap**

把 README "Requirements" 段里的 `macOS 13 or later.` 改为 `macOS 14 or later.`。
在 "Status & roadmap" 段,把 `- Single-file QuickLook preview` 这一条删除(本次实现),其余保留。

- [ ] **Step 4: 构建验证**

Run: `make build`
Expected: 构建成功,生成 `.build/YAUnarchiver.app`,无报错。

- [ ] **Step 5: Commit**

```bash
git add Package.swift Resources/Info.plist README.md
git commit -m "chore: raise minimum deployment target to macOS 14

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: ArchiveKit 纯逻辑(面包屑 + 预览路径)+ 单测

**Files:**
- Create: `Sources/ArchiveKit/Breadcrumb.swift`
- Create: `Sources/ArchiveKit/PreviewPaths.swift`
- Test: `Tests/ArchiveKitTests/BreadcrumbTests.swift`
- Test: `Tests/ArchiveKitTests/PreviewPathsTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `public struct BreadcrumbSegment: Equatable, Sendable { public let name: String; public let id: String; public init(name:String, id:String) }`
  - `public enum Breadcrumb { public static func segments(forPath path: String) -> [BreadcrumbSegment] }`
  - `public enum PreviewPaths { public static func fileURL(tempBase: URL, entryPath: String) -> URL }`

- [ ] **Step 1: 写失败的面包屑测试**

Create `Tests/ArchiveKitTests/BreadcrumbTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class BreadcrumbTests: XCTestCase {
    func test_segments_nested_path() {
        XCTAssertEqual(
            Breadcrumb.segments(forPath: "a/b/c"),
            [BreadcrumbSegment(name: "a", id: "a"),
             BreadcrumbSegment(name: "b", id: "a/b"),
             BreadcrumbSegment(name: "c", id: "a/b/c")]
        )
    }

    func test_segments_single_component() {
        XCTAssertEqual(
            Breadcrumb.segments(forPath: "only"),
            [BreadcrumbSegment(name: "only", id: "only")]
        )
    }

    func test_segments_empty_path_is_root_and_returns_empty() {
        XCTAssertEqual(Breadcrumb.segments(forPath: ""), [])
    }
}
```

- [ ] **Step 2: 写失败的预览路径测试**

Create `Tests/ArchiveKitTests/PreviewPathsTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class PreviewPathsTests: XCTestCase {
    func test_fileURL_nested_entry() {
        let base = URL(fileURLWithPath: "/tmp/ya")
        XCTAssertEqual(
            PreviewPaths.fileURL(tempBase: base, entryPath: "a/b/c.png").path,
            "/tmp/ya/a/b/c.png"
        )
    }

    func test_fileURL_top_level_entry() {
        let base = URL(fileURLWithPath: "/tmp/ya")
        XCTAssertEqual(
            PreviewPaths.fileURL(tempBase: base, entryPath: "c.png").path,
            "/tmp/ya/c.png"
        )
    }

    func test_fileURL_entry_with_spaces() {
        let base = URL(fileURLWithPath: "/tmp/ya")
        XCTAssertEqual(
            PreviewPaths.fileURL(tempBase: base, entryPath: "my dir/my file.txt").path,
            "/tmp/ya/my dir/my file.txt"
        )
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `make test`
Expected: 编译失败(`Breadcrumb` / `BreadcrumbSegment` / `PreviewPaths` 未定义)。

- [ ] **Step 4: 实现 Breadcrumb**

Create `Sources/ArchiveKit/Breadcrumb.swift`:

```swift
import Foundation

/// One clickable step in the right-pane breadcrumb bar.
public struct BreadcrumbSegment: Equatable, Sendable {
    /// Display name (last path component).
    public let name: String
    /// Full node id (cumulative path) this segment navigates to.
    public let id: String
    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }
}

/// Derives breadcrumb segments from a node's full path id (the tree uses a
/// "/"-joined path as its id; "" is the root). The root is NOT included — the
/// UI renders it separately.
public enum Breadcrumb {
    public static func segments(forPath path: String) -> [BreadcrumbSegment] {
        let components = path.split(separator: "/").map(String.init)
        var result: [BreadcrumbSegment] = []
        var accumulated = ""
        for component in components {
            accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
            result.append(BreadcrumbSegment(name: component, id: accumulated))
        }
        return result
    }
}
```

- [ ] **Step 5: 实现 PreviewPaths**

Create `Sources/ArchiveKit/PreviewPaths.swift`:

```swift
import Foundation

/// Resolves where a single entry lands after `7zz x -o<tempBase>` extraction.
/// `7zz x` preserves the archive-internal path, so the file appears at
/// tempBase/<entryPath>.
public enum PreviewPaths {
    public static func fileURL(tempBase: URL, entryPath: String) -> URL {
        tempBase.appendingPathComponent(entryPath)
    }
}
```

- [ ] **Step 6: 跑测试确认通过**

Run: `make test`
Expected: 全部 PASS(含既有测试)。

- [ ] **Step 7: Commit**

```bash
git add Sources/ArchiveKit/Breadcrumb.swift Sources/ArchiveKit/PreviewPaths.swift Tests/ArchiveKitTests/BreadcrumbTests.swift Tests/ArchiveKitTests/PreviewPathsTests.swift
git commit -m "feat(archivekit): add breadcrumb and preview-path pure helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: PreviewService(单文件解压 / 默认程序打开 / QuickLook 取 URL)

**Files:**
- Create: `Sources/SevenZipApp/PreviewService.swift`

**Interfaces:**
- Consumes:
  - `SevenZipRunner.extract(archive: URL, entries: [String]?, to: URL, password: String?) throws`(ArchiveKit)
  - `PreviewPaths.fileURL(tempBase:entryPath:) -> URL`(Task 2)
  - `ArchiveNode.id: String`(全路径)、`ArchiveNode.isDirectory`
- Produces:
  - `@MainActor final class PreviewService: ObservableObject`
    - `init(archiveURL: URL, runner: SevenZipRunner)`
    - `var password: String?`
    - `func url(for node: ArchiveNode) async throws -> URL`
    - `func open(_ node: ArchiveNode) async`

- [ ] **Step 1: 实现 PreviewService**

Create `Sources/SevenZipApp/PreviewService.swift`:

```swift
import Foundation
import AppKit
import ArchiveKit

/// Extracts single files on demand to a per-window temp directory, so the UI can
/// open them with the system default app or hand them to QuickLook. One instance
/// per archive window; the temp dir is removed when the instance deinits (i.e.
/// when the window closes).
@MainActor
final class PreviewService: ObservableObject {
    let archiveURL: URL
    private let runner: SevenZipRunner
    /// Kept in sync with the unlocked archive password by the owning window.
    var password: String?

    private let tempBase: URL
    private var cache: [String: URL] = [:]   // entry path -> extracted file URL

    init(archiveURL: URL, runner: SevenZipRunner) {
        self.archiveURL = archiveURL
        self.runner = runner
        self.tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("YAUnarchiver", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Ensures `node` is extracted to the temp dir and returns its local URL.
    /// Cached after the first extraction.
    func url(for node: ArchiveNode) async throws -> URL {
        if let cached = cache[node.id] { return cached }
        let runner = self.runner
        let archiveURL = self.archiveURL
        let password = self.password
        let tempBase = self.tempBase
        let entryPath = node.id
        let fileURL = try await Task.detached {
            try runner.extract(archive: archiveURL, entries: [entryPath], to: tempBase, password: password)
            return PreviewPaths.fileURL(tempBase: tempBase, entryPath: entryPath)
        }.value
        cache[node.id] = fileURL
        return fileURL
    }

    /// Extracts (if needed) and opens the file with the system default app.
    func open(_ node: ArchiveNode) async {
        guard let url = try? await url(for: node) else { return }
        NSWorkspace.shared.open(url)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempBase)
    }
}
```

- [ ] **Step 2: 构建验证**

Run: `make build`
Expected: 构建成功,无报错(可能有"未使用"类警告,可忽略)。

- [ ] **Step 3: Commit**

```bash
git add Sources/SevenZipApp/PreviewService.swift
git commit -m "feat(app): add PreviewService for on-demand single-file extraction

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 导航 + 多选(协议改造、面包屑、双击进目录、解压选中多选)

把右侧列表变成可导航、可多选,并让"解压选中"由多选驱动。QuickLook / 默认程序打开留到 Task 5。

**Files:**
- Modify: `Sources/SevenZipApp/BrowserLayout.swift`(整文件)
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`(整文件重写)
- Modify: `Sources/SevenZipApp/App.swift`(`ArchiveWindow`)

**Interfaces:**
- Consumes:
  - `PreviewService`(Task 3)
  - `Breadcrumb.segments(forPath:) -> [BreadcrumbSegment]`(Task 2)
  - `ArchiveNode`(`id/name/isDirectory/children`)
- Produces:
  - 新协议:`BrowserLayout.init(root:selection:previewService:onExtractSelected:)`,其中
    `selection: Binding<Set<ArchiveNode.ID>>`、`onExtractSelected: @escaping (Set<ArchiveNode.ID>) -> Void`。
  - `TwoPaneBrowserView` 存储 `previewService` 与 `onExtractSelected`(Task 5 使用),本任务实现导航与多选。

- [ ] **Step 1: 改 BrowserLayout 协议**

把 `Sources/SevenZipApp/BrowserLayout.swift` 整个替换为:

```swift
import SwiftUI
import ArchiveKit

/// Abstraction so future layouts (breadcrumb, single outline) are drop-in.
protocol BrowserLayout: View {
    init(root: ArchiveNode,
         selection: Binding<Set<ArchiveNode.ID>>,
         previewService: PreviewService,
         onExtractSelected: @escaping (Set<ArchiveNode.ID>) -> Void)
}
```

- [ ] **Step 2: 重写 TwoPaneBrowserView(导航 + 多选,无预览)**

把 `Sources/SevenZipApp/TwoPaneBrowserView.swift` 整个替换为:

```swift
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
```

- [ ] **Step 3: 改 ArchiveWindow(多选 + 注入 PreviewService + 密码同步)**

在 `Sources/SevenZipApp/App.swift` 的 `ArchiveWindow` 中做如下修改。

3a. 把选择状态从单值改成集合,并新增 `previewService` `@StateObject`。将:

```swift
    let archiveURL: URL
    @StateObject private var model: ArchiveViewModel
    @State private var selection: ArchiveNode.ID?
    @State private var passwordDraft = ""
```

改为:

```swift
    let archiveURL: URL
    @StateObject private var model: ArchiveViewModel
    @StateObject private var previewService: PreviewService
    @State private var selection: Set<ArchiveNode.ID> = []
    @State private var passwordDraft = ""
```

3b. 在 `init` 里初始化 `previewService`。将:

```swift
    init(archiveURL: URL) {
        self.archiveURL = archiveURL
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: archiveURL))
    }
```

改为:

```swift
    init(archiveURL: URL) {
        self.archiveURL = archiveURL
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: archiveURL))
        _previewService = StateObject(wrappedValue: PreviewService(
            archiveURL: archiveURL,
            runner: SevenZipLocator.bundledRunner()
        ))
    }
```

3c. 工具栏"解压选中"改用集合。将:

```swift
                    Button { extractSelected() } label: { Label("解压选中", systemImage: "arrow.down.square") }
                        .disabled(selection == nil || isExtracting)
```

改为:

```swift
                    Button { extractSelected(selection) } label: { Label("解压选中", systemImage: "arrow.down.square") }
                        .disabled(selection.isEmpty || isExtracting)
```

3d. 密码同步:把现有的 `.onChange(of: model.stateID)` 一行:

```swift
            .onChange(of: model.stateID) { _ in if case .needsPassword = model.state { showPasswordSheet = true } }
```

改为(顺带把单参数 `onChange` 升级为 macOS 14 的双参数形式,消除 deprecation 警告):

```swift
            .onChange(of: model.stateID) { _, _ in
                if case .needsPassword = model.state { showPasswordSheet = true }
                if case .loaded = model.state { previewService.password = model.password }
            }
```

3e. `.loaded` 分支把新参数传进布局。将:

```swift
        case .loaded(let root): TwoPaneBrowserView(root: root, selection: $selection)
```

改为:

```swift
        case .loaded(let root):
            TwoPaneBrowserView(
                root: root,
                selection: $selection,
                previewService: previewService,
                onExtractSelected: { ids in extractSelected(ids) }
            )
```

3f. 把 `extractSelected` 改成接收集合。将:

```swift
    private func extractAll() { runExtraction(selectedPaths: nil) }
    private func extractSelected() {
        guard let selection else { return }
        runExtraction(selectedPaths: [selection])
    }
```

改为:

```swift
    private func extractAll() { runExtraction(selectedPaths: nil) }
    private func extractSelected(_ ids: Set<ArchiveNode.ID>) {
        guard !ids.isEmpty else { return }
        runExtraction(selectedPaths: Array(ids))
    }
```

- [ ] **Step 4: 构建验证**

Run: `make build`
Expected: 构建成功,无报错。

- [ ] **Step 5: 手动 GUI 验证**

Run: `make run`(需先 `make fetch-7zz` 拉过 7zz),用一个多层目录的压缩包打开,确认:
1. 右侧同时显示文件与文件夹。
2. 双击文件夹 → 右侧进入其内容,面包屑更新,顶部返回键可用。
3. 点面包屑某一段 / 返回键能正确跳转;根目录时返回键禁用。
4. 右侧可单击选中、⌘/⇧ 多选;选中文件后"解压选中"可用,能把选中项解压出来。
5. 切换目录时右侧选择被清空。

Expected: 以上全部符合。

- [ ] **Step 6: Commit**

```bash
git add Sources/SevenZipApp/BrowserLayout.swift Sources/SevenZipApp/TwoPaneBrowserView.swift Sources/SevenZipApp/App.swift
git commit -m "feat(browser): navigable right pane with breadcrumb and multi-select

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 双击打开 + 空格 QuickLook + 右键菜单

**Files:**
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`

**Interfaces:**
- Consumes:
  - `PreviewService.open(_:) async`、`PreviewService.url(for:) async throws -> URL`(Task 3)
- Produces: 无(纯 UI 行为)

- [ ] **Step 1: 加 previewURL 状态与 quickLookPreview 修饰符**

在 `TwoPaneBrowserView` 的 `currentDirectoryID` 声明下方,新增一行状态:

```swift
    /// Non-nil while a file is shown in the QuickLook panel.
    @State private var previewURL: URL?
```

把 `body` 中 `NavigationSplitView { … } detail: { … }` 之后的修饰符链,由:

```swift
        .onChange(of: currentDirectoryID) { _, _ in selection = [] }
```

改为:

```swift
        .onChange(of: currentDirectoryID) { _, _ in selection = [] }
        .quickLookPreview($previewURL)
```

- [ ] **Step 2: fileTable 加空格键 QuickLook**

把 `fileTable` 里 `.contextMenu(forSelectionType:) { … } primaryAction: { … }` 之后追加 `.onKeyPress(.space)`,即把:

```swift
        .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            handlePrimaryAction(ids)
        }
    }
```

改为:

```swift
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
```

- [ ] **Step 3: 双击文件 → 默认程序打开**

把 `handlePrimaryAction` 里的注释分支补全。将:

```swift
    private func handlePrimaryAction(_ ids: Set<ArchiveNode.ID>) {
        guard ids.count == 1, let id = ids.first,
              let node = Self.find(id: id, in: root) else { return }
        if node.isDirectory {
            currentDirectoryID = node.id
        }
        // File open/preview added in the next task.
    }
```

改为:

```swift
    private func handlePrimaryAction(_ ids: Set<ArchiveNode.ID>) {
        guard ids.count == 1, let id = ids.first,
              let node = Self.find(id: id, in: root) else { return }
        if node.isDirectory {
            currentDirectoryID = node.id
        } else {
            Task { await previewService.open(node) }
        }
    }
```

- [ ] **Step 4: 右键菜单补全(打开 / 快速查看)+ singleSelectedFile 辅助**

把 `contextMenu(for:)` 由:

```swift
    @ViewBuilder
    private func contextMenu(for ids: Set<ArchiveNode.ID>) -> some View {
        Button("解压选中…") { onExtractSelected(ids) }
            .disabled(ids.isEmpty)
    }
```

改为(单选一个文件时提供"用默认程序打开 / 快速查看",并始终提供"解压选中"):

```swift
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
```

在 `// MARK: - Helpers` 下,`find` 方法上方,新增计算属性:

```swift
    /// The selected node when exactly one file (not a directory) is selected.
    private var singleSelectedFile: ArchiveNode? {
        guard selection.count == 1, let id = selection.first,
              let node = Self.find(id: id, in: root), !node.isDirectory else { return nil }
        return node
    }
```

- [ ] **Step 5: 构建验证**

Run: `make build`
Expected: 构建成功,无报错。

- [ ] **Step 6: 手动 GUI 验证**

Run: `make run`,用一个含图片/PDF/文本的压缩包(最好含加密包各测一次)打开,确认:
1. 双击一个图片文件 → 用系统默认程序打开(如"预览"/"图片")。
2. 单选一个文件按**空格** → 弹出访达同款 QuickLook 面板;再按空格/Esc 关闭。
3. 文件行右键 → 有"用默认程序打开 / 快速查看 / 解压选中…";文件夹或多选时只有"解压选中…"。
4. 加密包解锁后,以上打开/预览同样可用。
5. 关闭窗口后,`NSTemporaryDirectory()/YAUnarchiver/` 下对应的临时子目录被清理。

Expected: 以上全部符合。

- [ ] **Step 7: Commit**

```bash
git add Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(browser): double-click open, space QuickLook, and file context menu

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 完成后

- 五个任务跑完后,建议再做一次整支 branch review(subagent-driven-development 的收尾环节),重点核对:
  - `.onKeyPress(.space)` 是否会与 Table 的默认键处理冲突;
  - `PreviewService.deinit` 在 Swift 6 严格并发下是否编译通过(`tempBase` 为不可变 `let URL`,应可在 deinit 访问);
  - 加密包路径下 `previewService.password` 的同步时序。
- 本次不做(留待后续):从压缩包拖文件到 Finder;压缩/创建(含默认开启"排除 dotfiles");解压结果成功提示、错误弹窗等既有 minor。

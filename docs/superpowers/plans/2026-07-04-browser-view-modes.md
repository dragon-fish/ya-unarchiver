# 浏览视图模式(图标 / 列表)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给浏览器右侧内容区加一个可切换、可记忆的「大图标网格」视图,与现有详细列表并列。

**Architecture:** 在 `TwoPaneBrowserView` 内新增 `BrowserViewMode` 枚举、一个 `fileGrid`(LazyVGrid)计算属性与其选择/右键辅助,复用现有 helper(icon / handlePrimaryAction / contextMenu / makeDragProvider / selection);再用一个 `@AppStorage` 驱动的工具栏分段控件在 `fileTable` ↔ `fileGrid` 间切换,空格 QuickLook 上移到共享容器。

**Tech Stack:** Swift 6, SwiftUI, AppKit(NSEvent modifier flags, NSWorkspace icons),XcodeGen + xcodebuild(`make build`)。

## Global Constraints

- 部署 macOS 14.0,`SWIFT_VERSION 6.0`。面向用户文案:简体中文硬编码。
- **只改现有文件 `Sources/SevenZipApp/TwoPaneBrowserView.swift`,不新增源文件**(`BrowserViewMode` 放该文件内)→ `make build` 前**无需** `xcodegen generate`。
- 纯 UI/手势,无可单测的纯逻辑面 → 验证靠 `make build` + 手动。
- 两种模式交互一致;`BrowserLayout` 协议不动(这是右侧内容渲染模式,非整窗布局)。
- 网格选择:单击选中、⌘-单击多选;⇧-范围选不做。固定图标尺寸;文件用系统类型图标(不做缩略图)。
- Commit:英文 Conventional Commits;每个 Task 末尾 commit 一次。
- 在 `feat/browser-view-modes` 分支;不在 master 提交。

---

### Task 1: `BrowserViewMode` + `fileGrid` 网格视图(未接线)

**Files:**
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`

**Interfaces:**
- Consumes(既有,同文件):`sortedChildren: [ArchiveNode]`、`selection: Binding<Set<ArchiveNode.ID>>`、`Self.icon(for:) -> NSImage`、`handlePrimaryAction(_ ids: Set<ArchiveNode.ID>)`、`contextMenu(for ids: Set<ArchiveNode.ID>) -> some View`、`makeDragProvider(_:) -> NSItemProvider`。
- Produces(供 Task 2):`enum BrowserViewMode`、`fileGrid`(计算属性)、`toggleSelection(_:)`、`contextTargets(_:)`。

- [ ] **Step 1: 加 `BrowserViewMode` 枚举**

`Sources/SevenZipApp/TwoPaneBrowserView.swift` 顶部 `import` 之后(在 `struct TwoPaneBrowserView` 之前)加:

```swift
/// Right-pane content render mode. Persisted via @AppStorage.
enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case icon
    var id: String { rawValue }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var label: String { self == .list ? "列表" : "图标" }
}
```

- [ ] **Step 2: 加 `fileGrid` + 网格单元 + 选择/右键辅助**

在 `TwoPaneBrowserView` 内、`fileTable` 计算属性之后加:

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

- [ ] **Step 3: 构建验证(网格已存在但尚未显示)**

Run: `make build`
Expected: BUILD SUCCEEDED(`fileGrid`/辅助为私有、暂未引用,Swift 不对未用私有计算属性/方法告警)

- [ ] **Step 4: Commit**

```bash
git add Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(browser): add icon-grid view with shared selection/context/drag"
```

---

### Task 2: 工具栏切换 + 持久化 + 内容切换接线

**Files:**
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`

**Interfaces:**
- Consumes(Task 1):`BrowserViewMode`、`fileGrid`。
- Consumes(既有):`fileTable`、`singleSelectedFile`、`previewURL`、`previewService`。

- [ ] **Step 1: 加 `@AppStorage` 视图模式状态**

在 `TwoPaneBrowserView` 的 `@State private var previewURL: URL?`(约第 17 行)附近追加:

```swift
    @AppStorage("browserViewMode") private var viewMode: BrowserViewMode = .list
```

- [ ] **Step 2: 内容区按模式切换,并把空格 QuickLook 上移到共享容器**

`body` 的 `detail:` 里,把:

```swift
            VStack(spacing: 0) {
                fileTable
                Divider()
                pathBar
            }
```

改为:

```swift
            VStack(spacing: 0) {
                Group {
                    switch viewMode {
                    case .list: fileTable
                    case .icon: fileGrid
                    }
                }
                .onKeyPress(.space) {
                    guard let file = singleSelectedFile else { return .ignored }
                    Task { previewURL = try? await previewService.url(for: file) }
                    return .handled
                }
                Divider()
                pathBar
            }
```

并把 `fileTable` 计算属性末尾**原有的**这段 `.onKeyPress(.space)` 删除(它已上移到共享容器):

```swift
        .onKeyPress(.space) {
            guard let file = singleSelectedFile else { return .ignored }
            Task { previewURL = try? await previewService.url(for: file) }
            return .handled
        }
```

删除后 `fileTable` 以 `.contextMenu(forSelectionType:) { … } primaryAction: { … }` 结尾(Table 专属,保留不动)。

- [ ] **Step 3: 工具栏加视图切换分段控件**

`body` 的 `.toolbar { … }` 里,在现有返回按钮 `ToolbarItem` 之后追加:

```swift
            ToolbarItem(placement: .navigation) {
                Picker("视图", selection: $viewMode) {
                    ForEach(BrowserViewMode.allCases) { m in
                        Image(systemName: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .help("切换列表 / 图标视图")
            }
```

- [ ] **Step 4: 构建验证**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 手动验证**

Run: `make run`,确认:
1. 工具栏出现「列表 / 图标」分段控件(左侧,返回按钮旁);点击即时切换右侧内容。
2. **图标模式**:单击选中(高亮底色);⌘-单击加/减多选;双击文件夹进入下一层、双击文件用默认程序打开;右键出「用默认程序打开 / 快速查看 / 解压选中…」(单选文件时全有,多选/目录时按现有逻辑);从格子往 Finder 拖能拖出;选中单个文件按空格 QuickLook。
3. 切换模式后当前 `selection` 保持;进入下一层目录时选择清空(现有行为)。
4. **重启应用**后记住上次所选模式。
5. **列表模式无回归**:名称列单击/双击正常(上一修复仍生效),四列信息、右键、拖出、排序都正常。

- [ ] **Step 6: Commit**

```bash
git add Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(browser): toolbar view-mode switch with @AppStorage persistence"
```

---

## Self-Review

**Spec coverage:**
- §两种模式(列表 + 图标)→ Task 1(fileGrid)+ Task 2(switch)。✓ 分栏不做。
- §切换器(工具栏分段控件,list.bullet/square.grid.2x2)→ Task 2 Step 3。✓
- §持久化(@AppStorage "browserViewMode")→ Task 2 Step 1。✓
- §共享交互(选择/导航/右键/拖出/QuickLook/空格)→ Task 1(复用 helper)+ Task 2 Step 2(空格上移共享)。✓
- §图标网格(LazyVGrid + 大图标 + 名称截断,固定尺寸,系统图标)→ Task 1 Step 2。✓
- §网格选择(单击 + ⌘多选,⇧不做)→ Task 1 `toggleSelection`。✓
- §不拆文件、协议不动 → 全在 TwoPaneBrowserView.swift,BrowserLayout 未触碰。✓

**Placeholder scan:** 无 TBD/TODO;每个代码步骤含完整代码。✓

**Type consistency:** `BrowserViewMode`(Task 1 定义)→ Task 2 `@AppStorage`/Picker/switch 消费一致;`fileGrid`/`toggleSelection`/`contextTargets`(Task 1)→ Task 2 与网格单元消费一致;`handlePrimaryAction(_:)`/`contextMenu(for:)`/`makeDragProvider(_:)` 签名与现有文件一致(Set<ArchiveNode.ID> / some View / NSItemProvider)。✓

## 计划偏移 / 待同步(与用户)

1. **手势组合**:图标格用 `.onTapGesture`(单击选)+ `.simultaneousGesture(TapGesture(count:2))`(双击)+ `.onDrag`(拖出)。双击时单击手势可能也先触发一次(先选中再打开)——这与 Finder「先选后开」一致,可接受。若手动验证发现双击被单击吞或需两次点击,实现期改用 `.gesture(ExclusiveGesture(double, single))` 显式排他。
2. **工具栏位置**:视图切换 Picker 暂放 `.navigation`(左侧,返回键旁)。若与返回键挤或不美观,实现期可换 `.principal`(居中)。纯位置微调,不影响功能。

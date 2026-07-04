# 浏览视图模式(图标 / 列表)— 设计文档

日期:2026-07-04

## 背景与目标

右侧浏览区目前只有一种渲染:详细列表(`TwoPaneBrowserView` 里的 `Table`,名称/大小/压缩后/修改日期)。本批新增 **Finder 式视图模式切换**——在现有「详细列表」之外加一个**大图标网格视图**,工具栏一键切换,选择记忆。

范围只做 **图标 + 列表** 两种模式(列表已存在)。分栏视图(column view)是另一套导航范式、与侧栏目录树重叠,不在本批。

## 关键决策(已与用户确认)

1. **两种模式**:`列表`(现有 Table)+ `图标`(新增大图标网格)。分栏视图不做。
2. **切换器**:`TwoPaneBrowserView` 现有工具栏(返回按钮那组)加一个**分段控件**,SF Symbol `list.bullet` / `square.grid.2x2`。
3. **持久化**:`@AppStorage("browserViewMode")` 记住选择,跨窗口/重启保持。
4. **共享交互**:侧栏、路径栏、`selection` 绑定、导航、右键菜单、拖出、QuickLook、空格键在两模式间**完全共享**,不重复实现。
5. **图标网格**:`LazyVGrid` 自适应列;每格 = 大图标(复用现有 `Self.icon(for:)`,约 48–64pt)+ 名称(下方居中,截断)。固定尺寸,不做尺寸滑块;文件用系统类型图标,不做缩略图(均 YAGNI)。
6. **网格选择语义**:单击选中、⌘-单击切换多选。**⇧-范围选 v1 不做**(网格范围选需额外排序逻辑;列表模式本就支持完整多选)。
7. **不拆文件、协议不动**:`fileGrid` 作为 `TwoPaneBrowserView` 的计算属性与 `fileTable` 平行,复用所有现有 helper;`BrowserLayout` 协议不动(这是右侧内容的渲染模式,非整窗布局)。

## 架构与组件

### ① `BrowserViewMode` 枚举(SevenZipApp)

```swift
enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case icon
    var id: String { rawValue }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var label: String { self == .list ? "列表" : "图标" }
}
```

### ② `TwoPaneBrowserView` 改动

- 新增 `@AppStorage("browserViewMode") private var viewMode: BrowserViewMode = .list`(需 `@AppStorage` 支持 `RawRepresentable`,`BrowserViewMode: RawRepresentable` 由 `String` raw 满足)。
- 右侧内容区从「直接 `fileTable`」改为按 `viewMode` `switch`:
  ```swift
  Group {
      switch viewMode {
      case .list: fileTable
      case .icon: fileGrid
      }
  }
  ```
  (`fileTable` 保持现状不变;`fileGrid` 新增。)
- 工具栏在返回按钮那组之外,追加一个 `ToolbarItem`:
  ```swift
  Picker("视图", selection: $viewMode) {
      ForEach(BrowserViewMode.allCases) { m in
          Image(systemName: m.symbol).tag(m)
      }
  }
  .pickerStyle(.segmented)
  .help("切换列表 / 图标视图")
  ```

### ③ `fileGrid`(新增计算属性)

- `ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: <cell width>), spacing: …)]) { ForEach(sortedChildren) { cell } } }`。
- 每格 `cell(_ n:)`:
  ```swift
  VStack(spacing: 4) {
      Image(nsImage: Self.icon(for: n)).resizable()
          .frame(width: iconSide, height: iconSide)
      Text(n.name).font(.callout).lineLimit(2)
          .multilineTextAlignment(.center)
  }
  .frame(width: cellWidth)
  .padding(6)
  .background(selection.contains(n.id) ? Color.accentColor.opacity(0.25) : .clear,
              in: RoundedRectangle(cornerRadius: 8))
  .contentShape(Rectangle())
  .onTapGesture { toggleSelection(n.id) }            // 单击/⌘-单击
  .simultaneousGesture(TapGesture(count: 2).onEnded { handlePrimaryAction([n.id]) })  // 双击
  .onDrag { makeDragProvider(n) }                    // 拖出(位移触发,不与单击冲突)
  .contextMenu { contextMenu(for: contextTargets(n.id)) }  // 右键
  ```
- 选择处理:
  ```swift
  private func toggleSelection(_ id: ArchiveNode.ID) {
      if NSEvent.modifierFlags.contains(.command) {
          if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
      } else {
          selection = [id]
      }
  }
  ```
- 右键目标:若右键项已在多选内则对整组操作,否则对该单项(并将其设为选中),与 Finder 一致:
  ```swift
  private func contextTargets(_ id: ArchiveNode.ID) -> Set<ArchiveNode.ID> {
      selection.contains(id) ? selection : [id]
  }
  ```

### ④ 复用点(不改动语义)

- `handlePrimaryAction(_:)`、`contextMenu(for:)`、`makeDragProvider(_:)`、`Self.icon(for:)`、`sortedChildren`、`selection` 绑定、`.quickLookPreview`、`.onKeyPress(.space)`(挂在外层容器上,两模式共享)全部复用。
- **注意**:`.onKeyPress(.space)` 与右键 `contextMenu`/`primaryAction` 目前挂在 `fileTable` 上。改动时把「与视图无关」的修饰(空格 QuickLook)上移到 `switch` 外层容器,使两模式共享;列表的 `.contextMenu(forSelectionType:) { } primaryAction: { }` 是 `Table` 专属,保留在 `fileTable`,网格用自己的 `.contextMenu` + 双击手势。

## 受影响文件

- `Sources/SevenZipApp/TwoPaneBrowserView.swift` — 新增 `BrowserViewMode`(或单独小文件)、`@AppStorage viewMode`、工具栏 Picker、内容区 `switch`、`fileGrid` 计算属性及其选择/右键辅助。若文件显著变大,可把 `fileGrid` 及网格辅助拆到 `Sources/SevenZipApp/BrowserGridView.swift`(实现期视体量决定)。
- 新文件走 XcodeGen 目录 glob;若新增独立文件则 `make build` 前 `xcodegen generate`。

## 测试策略

- 视图模式是纯 UI/手势,无可单测的纯逻辑面;靠 `make build` + 手动验证:
  1. 工具栏分段控件切换 列表 ↔ 图标,内容即时切换。
  2. 图标模式:单击选中、⌘-单击多选、双击进目录/开文件、右键菜单(解压选中/打开/快速查看)、拖出到 Finder、空格 QuickLook。
  3. 切换模式后 `selection` 保持;重启应用后记住上次模式。
  4. 列表模式行为不回归(上一修复的名称列点击仍正常)。
- 若实现中出现可抽取的纯计算(如列宽/格宽),再补最小单测;当前 YAGNI。

## 非目标(本次不做)

- 分栏视图(column view / Miller columns)——另一套导航范式,与侧栏重叠。
- 图标尺寸滑块;文件缩略图(QuickLook thumbnail)。
- 网格内 ⇧-范围选;拖入排序/整理。
- 侧栏本身的视图模式(仅右侧内容区)。

## 计划偏移 / 待同步(执行中回填)

_(留给实现阶段:值得注意的选择或与本设计的偏移记录于此。)_

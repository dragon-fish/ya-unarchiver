# Finder 式图标网格（NSCollectionView 重做）— 设计文档

日期:2026-07-06

## 背景与目标

当前图标模式（`TwoPaneBrowserView` 里的 `fileGrid`）用 SwiftUI `LazyVGrid` + 手搓手势实现，先天缺失键盘焦点、橡皮筋框选、⇧-范围选、方向键、右键自动选中——这些不是 bug，是纯 SwiftUI 声明式网格的能力天花板。列表模式因用 SwiftUI `Table`（底层 `NSTableView`）白捡了这些。

本批把图标模式换底座：用 `NSViewRepresentable` 包一层 **`NSCollectionView`**（Finder 图标视图用的正是这个控件），复刻**完整 Finder 图标视图交互**。范围仅限右侧内容区的图标渲染模式;工具栏切换、`@AppStorage` 持久化、列表模式、所有交互 helper 全部保留复用。

## 关键决策（已与用户确认）

1. **只替换 `fileGrid`**:在当前 `feat/browser-view-modes` 分支上,把 `case .icon:` 渲染的 View 从 `LazyVGrid` 换成新的 `IconGridView`。不合并 LazyVGrid 过渡版;它只是 git 历史里的中间态。
2. **完整 Finder 交互**:单击选中、⌘-多选、⇧-范围选、橡皮筋框选、方向键导航、双击打开、右键自动选中+菜单、拖出到 Finder、空格 QuickLook——全部纳入(`NSCollectionView` 原生或半原生支持)。
3. **图标尺寸固定 48pt**,系统类型图标(复用 `Self.icon(for:)`),不做缩略图、不做尺寸滑块(YAGNI,沿用上一版决定)。
4. **不做拖入**(把 Finder 文件拖进网格添加/压缩)——YAGNI,非本批。
5. **QuickLook 复用现有机制**:空格键走现有 `previewURL` + SwiftUI `.quickLookPreview($previewURL)`,不引入 `QLPreviewPanel`,与列表模式同一套预览。
6. **右键菜单 AppKit 重建、动作共享**:列表模式用 SwiftUI `.contextMenu`,网格模式用 AppKit `NSMenu`;两者渲染两套但**共用同一批动作描述**(打开/快速查看/解压选中),避免逻辑漂移。
7. **可单测的纯逻辑抽到 ArchiveKit**:仿 `Breadcrumb` 先例,把"行索引 ↔ `ArchiveNode.ID`"映射做成 UI 无关纯函数放 ArchiveKit 并写 XCTest;桥接时序(防回环)靠 build + 人工冒烟。

## 架构与组件

### 新文件 `Sources/SevenZipApp/BrowserIconGrid.swift`

| 类型 | 职责 |
|---|---|
| `IconGridView: NSViewRepresentable` | SwiftUI ↔ AppKit 桥。入参见下。`makeNSView` 建 `NSScrollView`+`NSCollectionView`+`NSCollectionViewFlowLayout`;`updateNSView` 驱动数据刷新与选择同步。 |
| `IconGridView.Coordinator` | `NSCollectionViewDataSource` + `NSCollectionViewDelegate` + `NSFilePromiseProviderDelegate`;把 AppKit 选择/双击/右键/键盘事件翻译回 SwiftUI 的 `selection` 与注入闭包。持有当前 `nodes` 快照供索引换算。 |
| `IconGridItem: NSCollectionViewItem` | 单格:`NSImageView`(48pt 系统图标) + `NSTextField`(名称 `.callout`、居中、两行截断) + 选中态圆角高亮背景(accentColor 半透明)。 |
| `KeyCapturingCollectionView: NSCollectionView`(私有子类) | 重写 `keyDown` 拦截空格 → 注入的 `onQuickLook` 闭包;其余键盘事件(方向键)交回 `super` 走原生。 |

### `IconGridView` 入参(从 `TwoPaneBrowserView` 注入)

```swift
struct IconGridView: NSViewRepresentable {
    let nodes: [ArchiveNode]                       // = sortedChildren
    @Binding var selection: Set<ArchiveNode.ID>
    let onPrimaryAction: (ArchiveNode.ID) -> Void  // 双击 → handlePrimaryAction([id])
    let onQuickLook: () -> Void                     // 空格 → 现有 previewURL 逻辑
    let menuActions: (Set<ArchiveNode.ID>) -> [GridMenuAction]   // 右键菜单描述(见下)
    let dragProvider: (ArchiveNode) -> NSFilePromiseProvider     // 拖出承诺
}
```

### `TwoPaneBrowserView` 改动

- 删除 LazyVGrid 专属成员:`fileGrid`、`gridCell(_:)`、`gridIconSide`、`toggleSelection(_:)`、`contextTargets(_:)`(选择改由 `NSCollectionView` 原生接管)。
- `case .icon:` 改为构造 `IconGridView(nodes: sortedChildren, selection: $selection, onPrimaryAction: { handlePrimaryAction([$0]) }, onQuickLook: { … 现有空格逻辑 … }, menuActions: gridMenuActions, dragProvider: makeFilePromiseProvider)`。
- `.onKeyPress(.space)`(现挂在 `Group` 上)对图标模式不再需要(`NSCollectionView` 自己 keyDown 处理),但对列表模式(`Table`)仍需要——保留不动即可,图标模式下 `NSCollectionView` 抢先消费空格,`onKeyPress` 不会重复触发。
- 保留 `contextMenu(for:)`(列表模式 SwiftUI 菜单)与 `handlePrimaryAction`、`makeDragProvider`(见拖出小节:抽出共享的提取逻辑)不动语义。

## 交互接线明细

### 选择同步(双向,防回环)

- `NSCollectionView`:`isSelectable = true`、`allowsMultipleSelection = true`、`allowsEmptySelection = true`。单击/⌘/⇧/橡皮筋/方向键**全由原生处理**。
- **AppKit → SwiftUI**:`didSelectItemsAt`/`didDeselectItemsAt` 里把当前 `selectionIndexPaths` 映射成 `Set<ArchiveNode.ID>` 回写 `selection`。
- **SwiftUI → AppKit**:`updateNSView` 里先 diff——把传入 `selection` 换算成期望的 `Set<IndexPath>`,与 `collectionView.selectionIndexPaths` 比较,**仅不一致时**才 `selectItems`/`deselectItems`。
- **防回环双保险**:(a) Coordinator 上 `isSyncingSelection` 标志位,回写 binding 期间置位,`updateNSView` 见置位则跳过;(b) `updateNSView` 的 diff-before-apply 本身保证相等时不动手。
- 索引换算:`IndexPath.item ↔ Int 行号` 由 Coordinator 琐碎处理;`Int 行号 ↔ ArchiveNode.ID` 由 ArchiveKit 纯函数处理(见测试策略)。

### 双击打开

`NSCollectionView.doubleAction` + `target` 指向 Coordinator → 取 `clickedIndex`/首个选中项 → `onPrimaryAction(node.id)` → 复用 `handlePrimaryAction`(目录进入 / 文件用默认程序打开)。

### 右键(自动选中 + 菜单)

重写 collectionView 的 `menu(for event:)`:命中 item 若不在当前 `selection` 内,**先置为唯一选中**(回写 binding + `selectItems`),再据 `menuActions(targets)` 构建 `NSMenu`。空白处右键 → 仅"解压选中"(禁用态,因无选中)或不弹,与 Finder 一致。

菜单动作共享描述:

```swift
struct GridMenuAction {          // 定义在 BrowserIconGrid.swift(app 层,含 UI 语义)
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}
```

`TwoPaneBrowserView.gridMenuActions(_ ids:) -> [GridMenuAction]` 产出与 SwiftUI `contextMenu(for:)` **同一批动作**(单个文件:打开、快速查看;始终:解压选中),`perform` 闭包接 `previewService.open` / 设 `previewURL` / `onExtractSelected(ids)`。NSMenu 用 `NSMenuItem` + target/action 渲染,SwiftUI 侧继续用 `Button`。两处从同一语义来源生成,不各写一套判断。

### 拖出到 Finder

- `NSCollectionViewDelegate.collectionView(_:pasteboardWriterForItemAt:)` 返回 `NSFilePromiseProvider`(fileType 由节点扩展名/目录 UTI 决定,`delegate` = Coordinator)。
- `NSFilePromiseProviderDelegate`:`fileNameForType` 返回 `node.name`;`writePromiseTo url` 里 `await previewService.url(for: node)` 惰性提取后拷到目标 url。
- **DRY**:提取核心已经收敛在 `previewService.url(for: node)`(惰性提取到临时文件)。现有 `makeDragProvider`(`NSItemProvider` 版,供 SwiftUI `Table` 行拖拽)与新 `NSFilePromiseProvider` 版各自薄封装、都调这同一个 service 方法,无需再抽额外抽象层。列表模式的 `makeDragProvider` 保留不动。

### 空格 QuickLook

`KeyCapturingCollectionView.keyDown`:`event.charactersIgnoringModifiers == " "` 时调 `onQuickLook`(设 `previewURL` = 当前单选文件的预览 url,复用 `singleSelectedFile` + `previewService.url`),`return`;否则 `super.keyDown`。`NSCollectionView` 作为 first responder,空格自然到手——顺带消除上一版 LazyVGrid 空格失焦问题。

## 格子外观与数据刷新

- 布局:`NSCollectionViewFlowLayout`,`itemSize` 约 88×84,`minimumInteritemSpacing`/`minimumLineSpacing` ≈ 12,`sectionInset` ≈ 12(对齐现 `LazyVGrid(.adaptive(minimum:100), spacing:12)` 观感,自适应每行列数)。
- `IconGridItem`:`imageView`(48pt) 上、`textField`(居中两行截断)下;`isSelected` didSet 切换圆角高亮背景层。
- 数据刷新:`updateNSView` 中若 `nodes` 变化(进目录/换归档)`reloadData()`。目录切换时现有 `onChange(of: currentDirectoryID)` 已清空 `selection`,网格随之无选中——与列表模式一致。

## 测试策略

- **纯逻辑单测(ArchiveKit,仿 `Breadcrumb`)**:新增 `Sources/ArchiveKit/GridSelectionMapping.swift`(UI 无关,仅依赖 `ArchiveNode` + Foundation),提供:
  - `ids(forRows rows: [Int], in nodes: [ArchiveNode]) -> Set<ArchiveNode.ID>`
  - `rows(forIDs ids: Set<ArchiveNode.ID>, in nodes: [ArchiveNode]) -> [Int]`

  在 `Tests/ArchiveKitTests/GridSelectionMappingTests.swift` 覆盖:空集、全选、乱序、越界行、失效 id(不在 nodes 中被丢弃)、往返一致性。走 `DEVELOPER_DIR=… swift test --filter GridSelectionMapping`(SPM 自动 glob,新测试文件无需 regen)。Coordinator 消费这两个函数做 id↔行换算。
- **桥接/手势(无单测面)**:`xcodegen generate` + `make build` + 人工冒烟:
  1. 切换 列表 ↔ 图标,内容即时切换。
  2. 图标模式:单击选中、⌘-加减多选、⇧-范围选、橡皮筋框选、方向键移动选中、回车/双击 进目录/开文件、右键(未选中项自动选中)出菜单(打开/快速查看/解压选中)、拖出到 Finder、空格 QuickLook。
  3. 切换模式 `selection` 保持;进下级目录选择清空。
  4. 重启 App 记住上次模式(`@AppStorage` 未动)。
  5. 列表模式无回归(名称列点击、四列、右键、拖出、排序、空格预览)。

## 受影响文件

- 新增 `Sources/SevenZipApp/BrowserIconGrid.swift`(app target → **`xcodegen generate` 后 `make build`**)。
- 新增 `Sources/ArchiveKit/GridSelectionMapping.swift` + `Tests/ArchiveKitTests/GridSelectionMappingTests.swift`(SPM 自动 glob,无需 regen;`swift test` 可跑)。
- 修改 `Sources/SevenZipApp/TwoPaneBrowserView.swift`(删 LazyVGrid 成员、`case .icon:` 接 `IconGridView`、加 `gridMenuActions`、拖出核心抽取)。
- `BrowserLayout` 协议不动。

## 非目标(本次不做)

- 分栏视图(column view);图标尺寸滑块;文件缩略图。
- 拖入网格(添加/压缩);网格内重排。
- 侧栏视图模式;列表模式改动。

## 计划偏移 / 待同步(执行中回填)

_(留给实现阶段。)_

# 右侧文件列表交互增强 — 设计文档

日期:2026-07-02
分支:`feat/list-interaction`

## 背景与目标

v1 的双栏浏览里,右侧文件列表是**纯展示**:没有选择、没有双击、没有右键菜单。用户深度试用后反馈的头号问题就是"右侧完全没有交互"。

本次要把右侧列表做成访达式的可交互面板:

1. **双击文件夹进入**该目录(顶部面包屑 + 返回按钮导航)。
2. **双击文件**用系统默认软件打开(解压到临时目录再 `open`)。
3. **选中文件按空格** QuickLook 快速预览(访达同款)。
4. 右侧行**可单击/多选**,并以此驱动"解压选中"(不再只能选左侧目录)。
5. 文件行**右键菜单**:用默认程序打开 / 快速查看 / 解压选中。

这对应此前 brainstorming 里约定的"第二批"工作中的 ④ 单文件预览(Level 2),外加把右侧列表交互补齐(开发时被记为 deferred 项:Table 未接 selection)。

## 关键决策(已与用户确认)

- **min target 抬到 macOS 14**:可用原生 `.onKeyPress(.space)` 抓空格键,QuickLook 用 SwiftUI 原生 `.quickLookPreview($url)`,完全不碰 AppKit 的 `QLPreviewPanel`/响应链。README / Info.plist / Package.swift 一并改。
- **左侧目录树职责收敛为纯导航**;"解压选中"改由右侧表格的多选集合驱动。
- **右键菜单本次就带上**。
- **临时文件"窗口关就清"**:随 `PreviewService` 实例(一个窗口一个)deinit 清理。

## 架构与组件

### ① 导航模型(右侧面板)

- `TwoPaneBrowserView` 新增内部状态 `currentDirectoryID: ArchiveNode.ID`(默认根 `""`)。右侧表格展示"当前目录的 `children`",文件与文件夹都显示(此前只显示文件夹的逻辑仅用于左侧树)。
- **双击文件夹**(见 ③ 的 `primaryAction`)→ `currentDirectoryID = 文件夹.id`。
- 表格上方新增 **面包屑 + 返回按钮** 工具条:
  - 面包屑段:`根目录 › 子目录A › 子目录B …`,每段可点,点击跳到对应目录。
  - 返回按钮(`chevron.left`):回到父目录;在根目录时 `.disabled`。
- 左侧目录树 `selection` 与 `currentDirectoryID` **双向同步**:点左树 = 切当前目录;右侧进入子目录时左树高亮跟随。

### ② 行选择 + 解压选中

- 右侧 `Table` 接上 `selection: Binding<Set<ArchiveNode.ID>>`(单击选中、⌘/⇧ 多选)。
- 该集合**取代**原来喂给"解压选中"的单值 `selection`。`ArchiveWindow` 的"解压选中"按钮:`selectedIDs` 非空即可点;解压时把选中的 ID(即压缩包内路径)全部作为 `selectedPaths` 传入 `ExtractionController`。
- `BrowserLayout` 协议签名改为:

  ```swift
  protocol BrowserLayout: View {
      init(root: ArchiveNode,
           selection: Binding<Set<ArchiveNode.ID>>,
           previewService: PreviewService)
  }
  ```

### ③ 双击 / 右键菜单

用 macOS 13+ 就有的 `.contextMenu(forSelectionType:menu:primaryAction:)`:

- `primaryAction`(= 双击)拿到被双击行的 ID 集合:
  - 单个文件夹 → 导航进入。
  - 单个文件 → `previewService.open(node)`(默认软件打开)。
- `menu`(= 右键菜单),针对选中项:
  - 文件:**用默认程序打开**、**快速查看**。
  - 通用:**解压选中…**(触发与工具栏同一套解压流程)。

### ④ 打开 + QuickLook(新增 `PreviewService`)

新增 `Sources/SevenZipApp/PreviewService.swift`:

```swift
@MainActor
final class PreviewService: ObservableObject {
    let archiveURL: URL
    private let runner: SevenZipRunner
    var password: String?
    private let tempBase: URL           // NSTemporaryDirectory()/YAUnarchiver/<uuid>/
    private var cache: [String: URL]    // entry path -> extracted file URL

    init(archiveURL: URL, runner: SevenZipRunner)

    /// 确保单个文件已解压到临时目录并返回其本地 URL(命中缓存则直接返回)。
    func url(for node: ArchiveNode) async throws -> URL

    /// 用系统默认软件打开(内部调用 url(for:) 后 NSWorkspace.shared.open)。
    func open(_ node: ArchiveNode) async

    deinit  // 清理 tempBase(best-effort)
}
```

- `url(for:)`:命中缓存直接返回;否则 `Task.detached` 里调用
  `runner.extract(archive:, entries: [node.id], to: tempBase, password:)`,
  用纯函数 `previewFileURL(tempBase:, entryPath:)` 算出结果 URL,写缓存后返回。
- 只处理**文件**;文件夹的双击走导航,不进入本服务。
- 密码由 `ArchiveWindow` 同步(见 ⑤)。

QuickLook 接线(在 `TwoPaneBrowserView`):

- `@State private var previewURL: URL?`
- 详情区加 `.quickLookPreview($previewURL)`。
- `.onKeyPress(.space)`:当且仅当选中集合里是**单个文件**时,`previewURL = try await previewService.url(for: node)`;否则不处理(返回 `.ignored`)。

### ⑤ 密码联动

- `ArchiveWindow` 持有 `@StateObject previewService`,在 `.onChange(of: model.stateID)` 里,当状态变为 `.loaded` 时同步 `previewService.password = model.password`。保证加密包解锁后也能预览/打开。

### ⑥ 临时文件生命周期

- `tempBase` = `NSTemporaryDirectory()/YAUnarchiver/<uuid>/`,一窗口一实例。
- `PreviewService.deinit` 中 `try? FileManager.default.removeItem(at: tempBase)`;系统对 temp 目录亦有兜底回收。

## 可测试的纯逻辑(放进 ArchiveKit)

新增到 ArchiveKit(纯 Foundation、可单测):

- `breadcrumbSegments(forPath path: String) -> [(name: String, id: String)]`
  - 输入 `"a/b/c"` → `[("a","a"), ("b","a/b"), ("c","a/b/c")]`;输入 `""` → `[]`(根由 UI 单独渲染)。
- `previewFileURL(tempBase: URL, entryPath: String) -> URL`
  - `tempBase.appendingPathComponent(entryPath)`,与 `7zz x -o<tempBase>` 保留内部路径结构的行为一致。

单测覆盖:嵌套路径、单层路径、空路径、带特殊字符的路径。UI 接线(Table selection / onKeyPress / quickLookPreview / contextMenu)靠手动 GUI 验证。

## 受影响文件

- `Package.swift` — platforms `.macOS(.v14)`。
- `Resources/Info.plist` — `LSMinimumSystemVersion` 14.0。
- `README.md` — "macOS 14 或更新";roadmap 勾掉单文件预览。
- `Sources/ArchiveKit/` — 新增 breadcrumb / preview-path 纯函数(可放入一个新文件如 `PreviewPaths.swift` / `Breadcrumb.swift`)。
- `Sources/SevenZipApp/BrowserLayout.swift` — 协议签名。
- `Sources/SevenZipApp/TwoPaneBrowserView.swift` — 导航状态、面包屑、Table selection、双击/右键、onKeyPress、quickLookPreview。
- `Sources/SevenZipApp/PreviewService.swift` — 新增。
- `Sources/SevenZipApp/App.swift`(`ArchiveWindow`)— selection 改 `Set`、注入并同步 `PreviewService`、解压选中改多选。
- `Tests/ArchiveKitTests/` — breadcrumb / preview-path 单测。

## 非目标(本次不做)

- 从压缩包拖文件到 Finder(第二批的 ③,后续单独做)。
- 压缩 / 创建压缩包(含默认开启的"排除 dotfiles")。
- 预览时的错误弹窗打磨、解压结果成功提示等既有 deferred 的 minor(不在本次范围)。

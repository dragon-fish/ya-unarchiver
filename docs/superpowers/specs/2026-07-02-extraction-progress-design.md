# 解压进度条 — 设计文档

日期:2026-07-02

## 背景与目标

解压当前是"点一下,等着,好了给反馈",过程中无任何进度指示。目标:解压期间显示进度条。用户接受"能估真实进度最好,否则假的"。

**调研结论(实测打包的 7zz 25.01):**

- 管道模式(非 TTY,应用用 `Pipe` 跑子进程)下 `-bsp1` **不吐百分比**——7-Zip 的百分比进度用 `\r` 原地刷新,只在交互终端出现。
- 但 `-bb1`(log level = show names)在**管道模式下正常逐条目流式输出** `- <路径>` 行,每解压一个条目一行(文件与目录都有)。

因此**真实进度可做**:边解压边数 `- ` 行 / 总条目数。非字节级精确,但真实、单调递增。

## 关键决策(已与用户确认)

- **策略:先真,自动退化到假**。进度从 indeterminate 起步;收到第一条 `- ` 行且分母已知时切为 determinate;若某压缩包全程不吐 `- ` 行则一直停在 indeterminate 动画——每次自动判定,无特殊分支。
- **按文件条目计数**,非字节权重(更简单)。
- **无取消按钮**(YAGNI;取消需 terminate 进程,非本次需求)。
- **中央半透明遮罩 + 卡片**呈现,非底部细条。

## 架构与组件

### ① Runner 流式改造(`SevenZipRunner`)

现在 `private func run(_:)` 用 `readDataToEndOfFile()` 一次性读到进程结束。新增一条**逐行流式**路径,仅当调用方传进度回调时启用:

- 新增私有方法,示意:

```swift
private func runStreaming(_ arguments: [String], onLine: @Sendable (String) -> Void) throws -> RunResult
```

- 用 `Pipe.fileHandleForReading` 按块读取、按 `\n` 切行,对每行调用 `onLine`;进程结束后收尾。stderr 仍整读用于错误分类(与现有逻辑一致)。

`extract` 方法增加**可选进度回调**。签名演进(保持向后兼容——回调默认 nil 时走原快路径,不加 `-bb1`):

```swift
// 4 参 -> 5 参(加 onEntryExtracted)
public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?,
                    onEntryExtracted: (@Sendable () -> Void)? = nil) throws

// 单顶层目录版透传回调
public func extract(archive: URL, entries: [String]?, singleTopLevelDir: String?,
                    to finalFolder: URL, password: String?,
                    onEntryExtracted: (@Sendable () -> Void)? = nil) throws
```

- `onEntryExtracted != nil` 时:参数加 `-bb1`,走 `runStreaming`,对每条以 `- ` 开头的行触发一次回调;`== nil` 时:走原 `run`,不加 `-bb1`(`PreviewService` / 拖出 / 现有测试不受影响)。
- `temp+move` 路径把回调透传给内部解压调用;计数只发生在解压阶段(move 很快,不计)。
- 回调在 `Task.detached` 线程触发,是 `@Sendable`;marshal 回主线程由 `ExtractionController` 负责。

**`- ` 行判定**:`line.hasPrefix("- ")`。7zz `-bb1` 对每个被解出的条目(文件和目录)输出一行 `- <archive-internal-path>`;banner/摘要行不以 `- ` 开头。计数只关心"有多少条",不关心具体路径。

### ② 分母:总条目数(`ExtractionProgress` 纯逻辑)

新增一个纯逻辑单元(单测友好),从 `[ArchiveEntry]` + `selectedPaths` 求解 7zz 将解出的条目总数:

```swift
enum ExtractionProgress {
    /// Total number of entries 7zz will emit `- ` lines for.
    /// - selectedPaths == nil: 全部条目数(files + dirs)。
    /// - 否则:path 等于某个选中路径、或以 "<选中路径>/" 为前缀的条目数(子树)。
    static func totalEntryCount(entries: [ArchiveEntry], selectedPaths: [String]?) -> Int
}
```

- 分母是估计值:实际 7zz 可能为被选文件重建祖先目录而多输出几行,导致计数**略微超过**分母 → UI 侧 `clamp` 到 1.0,可接受。
- 分母为 0 时 → 直接 indeterminate。

### ③ `ExtractionController` 汇报进度

`extract(...)` 增加一个进度回调参数(`@MainActor`,由 window 提供),把已完成计数与总数报给 UI:

```swift
func extract(
    archive: URL, entries: [ArchiveEntry], selectedPaths: [String]?, password: String?,
    resolveCollision: (URL) async -> CollisionChoice,
    onProgress: @MainActor (_ completed: Int, _ total: Int) -> Void   // 新增
) async throws -> URL
```

- 解压前算 `total = ExtractionProgress.totalEntryCount(...)`。
- 传给 `runner.extract` 的 `onEntryExtracted`:一个 `@Sendable` 闭包,内部计数 +1 并 `Task { @MainActor in onProgress(count, total) }` 送回主线程(用一个线程安全计数器,如 `OSAllocatedUnfairLock` 或 actor;或简单地在闭包里用一个 `Sendable` 引用计数)。
- 完成后照常返回目标 URL。

### ④ UI(`ArchiveWindow` + 进度模型)

- 进度状态:

```swift
enum ExtractionProgressState { case indeterminate; case determinate(fraction: Double) }
@State private var progress: ExtractionProgressState?   // nil = 不显示
```

- `runExtraction` 开始时置 `progress = .indeterminate`;`onProgress(completed, total)` 回调里:`total > 0` 时置 `.determinate(min(1, Double(completed)/Double(total)))`,否则保持 indeterminate;`defer`/完成/失败时置 `progress = nil`。
- 遮罩 overlay(在现有 toast overlay 附近):`progress != nil` 时显示半透明背景 + 居中卡片:
  - determinate:`ProgressView(value: fraction)`(线性条)+ 文案「正在解压… \(Int(fraction*100))%」。
  - indeterminate:`ProgressView()`(转圈)+ 文案「正在解压…」。
- 遮罩期间用户已被 `isExtracting` 挡住操作;遮罩不可手动关闭,无取消按钮。

## 受影响文件

- `Sources/ArchiveKit/SevenZipRunner.swift` — `runStreaming` + `extract` 加可选进度回调 + `-bb1`。
- `Sources/ArchiveKit/ExtractionProgress.swift`(新增) — `totalEntryCount` 纯逻辑。
- `Sources/SevenZipApp/ExtractionController.swift` — 算 total、透传 `onEntryExtracted`、marshal `onProgress`。
- `Sources/SevenZipApp/App.swift` — `ExtractionProgressState`、`runExtraction` 驱动进度、遮罩 overlay。
- 新增小组件文件(可选):`Sources/SevenZipApp/ExtractionProgressOverlay.swift`(遮罩卡片)。
- `Tests/ArchiveKitTests/ExtractionProgressTests.swift`(新增) — `totalEntryCount` 单测。
- `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` — 加一个真实 `-bb1` 进度集成测试。

## 测试策略

- **纯逻辑单测**:`ExtractionProgress.totalEntryCount` —— 全部条目、选中单文件、选中目录(含子树)、选中路径前缀不误伤同名兄弟(如选 `a` 不应计入 `ab/…`)。
- **`- ` 行解析单测**:喂一段含 banner + `- path` 行 + 摘要的样本文本给解析计数逻辑,断言只数到条目行。若解析逻辑内联在 `runStreaming` 不便单测,则抽一个纯函数 `SevenZipRunner.isEntryLine(_:) -> Bool`(或计数器)单测。
- **集成测试**(真实 7zz,`/opt/homebrew/bin/7z`):对多文件 fixture 调 `extract(... onEntryExtracted:)`,收集回调次数,断言 `>= 文件数` 且解压成功;确认回调确实被触发(证明 `-bb1` 流式在管道下工作)。
- 遮罩 UI、determinate/indeterminate 切换 = `make build` + 手动 GUI 验证。

## 非目标(本次不做)

- 取消解压(terminate 进程)。
- 字节级精确进度 / 单文件内进度。
- 压缩(创建)进度——压缩功能本身尚未做。
- 拖出 / 单文件预览的进度(操作快,无需)。

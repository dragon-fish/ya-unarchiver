# 创建压缩包(Compression v1)— 设计文档

日期:2026-07-03

## 背景与目标

应用目前「以归档为中心」:`WindowGroup(for: URL)` 打开一个已有归档来浏览/解压,欢迎窗只能打开/拖入一个**已有归档**。本批新增反向能力——从一堆**散文件/文件夹**出发**创建**一个新归档(memory 里的「C 类别」,曾明确排在解压对话框之后)。

v1 聚焦一个务实、可测的创建流程;把 memory 愿景里那套「7z 参数全量图形化选单」(优先级排序、高级折叠、推荐默认)留给 v2。相关 memory:`extraction-compression-gui-options-vision`、`compression-exclude-dotfiles`。

**7zz 真实能力核对(`7zz i`,内置 25.01)**:首列带 `C` = 支持创建。能压缩且原生支持「多文件 + 文件夹结构」的归档格式只有 **7z / zip / tar / wim**;gzip/bzip2/xz 是单流压缩器(压文件夹须先 tar);官方版 **zstd 只能解不能压**。故 v1 取 **7z + zip**。

## 关键决策(已与用户确认)

1. **入口**:欢迎窗「创建压缩包…」按钮 + 文件菜单「新建压缩包…」(⌘N)。两者都先弹 `NSOpenPanel`(多选、可选文件**和**文件夹)选源,再进创建对话框。
2. **Finder 右键/服务集成**(`NSServices`)排为压缩功能里**紧随其后的独立切片**,喂给同一个创建对话框;v1 核心不含它。
3. **格式**:v1 = **7z + zip**(都原生支持多文件/文件夹 + 加密,一次 `7zz a` 搞定)。
4. **v1 选项边界**:核心字段(输出位置+名称、格式、压缩等级、密码、排除 dotfiles、路径预览、已存在时处理)+ **一个高级项「加密文件名/头」(`-mhe`,仅 7z)**。固实、分卷、线程/方法 → v2。
5. **加密文件名/头**:仅「7z + 有密码」时可见,默认勾上(不然别人能看到 7z 包里的文件名)。
6. **排除 dotfiles**:默认**开**(`-xr!.*`)。
7. **防呆哲学**沿用解压对话框:不拦/不篡改输入;非法只以 UI 反馈(红框+红字+禁用「创建」);常驻「将创建 `<绝对路径>`」预览;还原默认按钮;双层防御(UI + 纯函数抛错兜底)。
8. **CompressionOptions 做成与 ExtractOptions 平行的纯值类型**(纯 `validate`/`resolveOutput`/`defaults` + 参数组装,可单测)。

## 创建对话框字段(自上而下)

1. **源** — 只读摘要「N 项 · 合计 XX MB」。v1 不在对话框内增删源(YAGNI)。
2. **保存到** — 输出目录文本框 + `…`(NSOpenPanel 选目录)+ 条件还原按钮。默认=源的最深公共父目录。
3. **压缩包名** — 文本框 + 条件还原按钮。默认名见 §源映射与命名。
4. **格式** — 分段控件 `7z / zip`。切换时输出扩展名自动跟随。
5. **压缩等级** — 下拉:`仅存储 / 最快 / 普通(默认) / 最好 / 极限`。映射 `-mx=0/1/5/7/9`。
6. **密码** — 文本框 + 「显示密码」勾选。留空=不加密。
7. **加密文件名/头** — 勾选框,仅 7z + 密码非空时出现,默认勾上。
8. **排除 dotfiles** — 勾选框,默认开。
9. **将创建:`<解析后的绝对路径>`** — 常驻预览行(展开 `~`、归一 `../.`,含最终扩展名)。「已存在时」黄色提示或前置策略见 §碰撞。
10. 底部:`取消` / `创建`(校验通过才可用)。

## 架构与组件

### ① `ArchiveFormat`(ArchiveKit,新增)

```swift
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case sevenZip   // "7z"
    case zip
    public var fileExtension: String { self == .sevenZip ? "7z" : "zip" }
    public var typeFlag: String { self == .sevenZip ? "7z" : "zip" }  // 7zz -t<...>
    public var supportsHeaderEncryption: Bool { self == .sevenZip }   // -mhe 仅 7z
}
```

### ② `CompressionLevel`(ArchiveKit,新增)

```swift
public enum CompressionLevel: Int, Sendable, CaseIterable {
    case store = 0, fastest = 1, normal = 5, maximum = 7, ultra = 9
    // 传给 7zz 的 -mx=<rawValue>
}
```
默认 `.normal`。

### ③ `CompressionOptions`(ArchiveKit,新增;纯值 + 纯逻辑,重点单测)

```swift
public struct CompressionOptions: Sendable {
    public var items: [URL]            // 源(绝对路径)
    public var outputDirectory: URL    // 保存到(容器,已归一)
    public var archiveName: String     // 不含扩展名
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String
    public var encryptHeader: Bool     // -mhe;仅 7z + 有密码时有意义
    public var excludeDotfiles: Bool
}
```

纯逻辑(可单测):
- `validate() -> [CompressionValidationError]`:`items` 非空;`outputDirectory` 校验同 ExtractOptions 放宽版(最近已存在祖先须为可写目录,不存在可创建);`archiveName` 去空白后须为**单一合法路径分量**(不含 `/`/`:`,非 `.`/`..`,非空)。
- `resolveOutput() throws -> URL`:`outputDirectory/(archiveName).<format.fileExtension>`;非法抛 `ArchiveError.invalidDestination`。
- `static func defaults(items:[URL]) -> CompressionOptions`:见 §源映射与命名。
- `commonParent(of items:) -> URL`:所有 items 的最深公共父目录(工作目录 + 相对路径的基准)。
- `arguments(output:) -> [String]`:组装 `7zz a` 参数(见 §后端)。

### ④ 源映射与命名(纯逻辑)

- **映射**:working directory = `commonParent(items)`;每个 item 以「相对公共父目录的路径」加入。同目录多选 → 各项以自身名字落在包根,不带绝对路径污染。
- **默认名**:单选 → 该项 `lastPathComponent`(文件夹 `proj`→`proj`;文件 `a.txt`→`a.txt`,即含原扩展名再 `.7z`);多选 → 公共父目录名,取不到(如根)则 `Archive`。
- **默认输出目录** = 公共父目录。

### ⑤ 后端 `SevenZipRunner.compress(...)`(ArchiveKit)

```swift
public func compress(options: CompressionOptions, to output: URL,
                     onProgress: (@Sendable (_ percent: Int) -> Void)? = nil) throws
```
- 参数组装(`arguments`):`a -t<typeFlag> -mx=<level> -y`
  - 密码非空:`-p<pwd>`;7z + encryptHeader:`-mhe=on`;zip 加密:`-mem=AES256`。
  - excludeDotfiles:`-xr!.*`。
  - 进度:`-bsp1`(百分比到 stdout)。
  - 末尾 `<output.path>` 再跟各相对 item 路径。
- **working directory** 设为公共父目录(`Process.currentDirectoryURL`),使 item 以相对路径入包。
- **进度**:复用 `runStreaming` 思路,解析 `-bsp1` 的百分比行驱动回调。
- 退出码非 0 → 分类抛错(密码/磁盘满/通用),与 extract 一致。

### ⑥ 控制器 + 碰撞 + 反馈(SevenZipApp)

- `CompressionController`(仿 `ExtractionController`,@MainActor):`resolveOutput` → 文件级碰撞(输出已存在:`询问/带序号/删除`,`Archive.7z`→`Archive 2.7z`,复用 `ExtractionTarget.numbered` 思路)→ 后台 `Task.detached` 跑 `runner.compress` → 进度回调 → 返回最终输出 URL。
- **进度覆盖层**复用 `ExtractionProgressOverlay`(百分比模式);措辞抽象为「正在压缩…」/「正在解压…」二选一,或抽出通用 overlay。
- **成功反馈**复用 `PostExtractAction` 同款(打开 Finder / 应用内提示 / 不提示)。
- **密码**:创建时密码由用户在对话框内填,无「错误重试」概念(压缩不校验既有密码)。

### ⑦ 对话框视图 `CreateArchiveView`(SevenZipApp)

仿 `ExtractOptionsView`:输入 = 初始 `CompressionOptions`(默认值)+ 回调 `onCreate(CompressionOptions)`/`onCancel`;内部 `@State` 草稿;实时算预览 + 校验(调 ArchiveKit 纯函数);格式切换驱动扩展名;还原按钮按「值≠默认」显示;视图不含压缩逻辑。

### ⑧ 入口接线(App.swift / WelcomeView)

- 文件菜单在「打开…」旁加 **「新建压缩包…」(⌘N)**;`CommandGroup(replacing: .newItem)` 里已有打开,追加此项(⌘N 独立于 ⌘O)。
- `WelcomeView` 加「创建压缩包…」按钮。
- 两处都走 `presentSourceOpenPanel()`(多选、canChooseFiles+canChooseDirectories)→ 有选中则打开**专用创建窗**承载 `CreateArchiveView` + 进度 + 反馈。
- **窗口方案(定)**:新增第二个 `WindowGroup(for: CreateArchiveRequest.self)`(`CreateArchiveRequest: Codable, Hashable`,携带 `items: [URL]`),与现有 `WindowGroup(for: URL.self)` 并存。选完源即 `openWindow(value: CreateArchiveRequest(items:))`。这样菜单在无窗口态触发也稳妥(不依赖 key window),且与现有「归档窗」架构一致。对话框「取消」或创建成功后关窗。

## 受影响文件

- 新增 `Sources/ArchiveKit/ArchiveFormat.swift`、`CompressionLevel.swift`(或并入)、`CompressionOptions.swift`(值 + 纯逻辑 + 参数组装)。
- `Sources/ArchiveKit/SevenZipRunner.swift` — 新增 `compress(...)`。
- `Sources/ArchiveKit/ArchiveError.swift` — 复用 `invalidDestination`;按需加压缩相关分类。
- 新增 `Sources/SevenZipApp/CreateArchiveView.swift`、`CompressionController.swift`。
- `Sources/SevenZipApp/App.swift` — ⌘N 菜单项、源 NSOpenPanel、创建对话框/进度/反馈接线。
- `Sources/SevenZipApp/WelcomeView`(在 App.swift 内)— 创建按钮。
- 进度覆盖层措辞/复用 `ExtractionProgressOverlay.swift`。
- 新文件走 XcodeGen 目录 glob,无需改 `project.yml`(新 app 文件 `make build` 前需 `xcodegen generate`)。

## 测试策略

- **纯逻辑单测**(`Tests/ArchiveKitTests/CompressionOptionsTests.swift`):
  - `validate`:items 空;输出目录不存在但可创建 / 穿过文件 / 不可写根;archiveName 含 `/`/`:`/`.`/`..`/空白。
  - `resolveOutput`:目录+名+格式扩展名;格式切换扩展名跟随。
  - `defaults`:单选(文件/文件夹)、多选(公共父目录名 / 根回退 `Archive`)。
  - `commonParent`:同目录、跨目录、单项。
  - `arguments`:给定选项 → 期望 `7zz a` 参数数组(等级/密码/-mhe 仅7z/zip AES/-xr!.* /-bsp1/相对路径)。
- **集成**(有 7zz 时,`Tests/ArchiveKitTests`):压小 fixture → `7zz l` 校验条目与相对路径;`-xr!.*` 确实滤掉 `.DS_Store`;加密包 `7zz l` 需密码。若测试环境无 7zz 则降级手动验证并在计划注明。
- 对话框/入口/进度/反馈 = `make build` + 手动 GUI。

## 非目标(v1 不做)

- 固实开关、分卷(`-v`)、线程/方法选择 → v2「7z 参数全量图形化选单」。
- tar.gz/tar.xz、wim 及其他格式;zstd 压缩(二进制不支持)。
- Finder 服务集成(→ 紧随其后的独立切片)。
- 对话框内增删源;拖散文件到欢迎窗创建。
- 更新已有归档(`7zz a` 到已存在包内追加)——v1 走碰撞覆盖,不做「追加到现有包」。

## 计划偏移 / 待同步(执行中回填)

_(留给实现阶段:值得注意的选择或与本设计的偏移记录于此。)_

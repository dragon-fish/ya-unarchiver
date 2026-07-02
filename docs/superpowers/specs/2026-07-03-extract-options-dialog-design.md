# 解压选项对话框(仿 Windows 7-Zip「解压」)— 设计文档

日期:2026-07-03

## 背景与目标

当前解压是「一键极速」模式:点工具栏「解压全部/解压选中」→ `ExtractionController` 自动定目标(包所在目录 + 智能子文件夹名)、只有目标夹碰撞时才反应式弹框确认。这一路要**保留**。

本批新增一条「慢路」:一个仿 Windows 7-Zip「解压」对话框,让用户在解压前显式设置**解压位置、子文件夹、是否排除重复根目录、目标已存在时的行为、密码**。参考愿景见 memory `extraction-compression-gui-options-vision`。

这是该 memory 里「点击解压的选项对话框」独立 spec,复用已完成的统一解压原语(`SevenZipRunner.extract(entries:singleTopLevelDir:…)`)、进度覆盖层、成功/失败反馈。

**本批不做**:压缩 / 创建归档(C 类别,另起 spec);7z 参数全量图形化选单;文件级 `-ao*` 覆盖策略;路径模式(完整/无路径);「高级」可折叠区。

## 关键决策(已与用户确认)

1. **快慢双路**:工具栏「解压全部」「解压选中」保持一键极速(默认选项);新增「解压到…(选项)」入口才弹对话框。两条路**汇入同一个** `ExtractionController.extract`,一键路用默认 `ExtractOptions`,对话框路用用户编辑后的 `ExtractOptions`。
2. **入口形态**:两个工具栏按钮改为 `Menu(primaryAction:)` 分体样式——主体点击=一键;右侧下拉=「解压到…(选项)」。列表右键菜单已有的「解压选中…」接到对话框。
3. **覆盖粒度=文件夹级**:复用现有 `CollisionChoice`(`.cancel/.deleteExisting/.numbered`),不引入 7zz 文件级 `-ao*`。
4. **目标模型**:两个输入框——
   - **解压位置**(容器目录),默认=压缩包所在目录,右侧 `…` 按钮调 `NSOpenPanel` 选目录。
   - **到文件夹**(带勾选框),默认勾选、填入包名。勾选 → `位置/名字`;取消勾选或留空 → 直接铺进「解压位置」。
5. **排除重复的根文件夹**:勾选框,默认开——把现有「自动去除单一同名根目录」逻辑升级为可见开关(`stripSingleTopDir`)。
6. **已存在时**:前置下拉 `询问`(默认)/ `解压到带序号文件夹` / `删除原文件夹`,直接映射 `CollisionChoice`。选「询问」= 保留反应式碰撞框;选另两项 = 确认时即决定,不再二次弹框。
7. **路径模式砍掉**,固定完整路径。
8. **输入校验哲学**:永不拦截/篡改用户输入(用户想填 `../!@#$` 就让他填);合法性只通过 UI 反馈体现——非法字段红框 + 内联红字 + `解压` 按钮禁用。双层防御:UI 实时校验 + ArchiveKit 纯函数复校(抛 `ArchiveError.invalidDestination`)。
9. **还原默认**:解压位置 / 到文件夹 各配一个 `arrow.clockwise`,**仅当该框值 ≠ 默认时才出现**,点击复位到智能默认。
10. **密码错误自包含**:对话框内解压若 `wrongPassword`,重新呈现对话框 + 内联报错原地重试,不借用独立密码 sheet。

## 对话框字段(自上而下,按常用度)

1. **解压位置** — 文本框 + `…`(NSOpenPanel 选目录)+ 条件出现的 `arrow.clockwise` 还原。
2. **到文件夹** — 勾选框 + 文本框(默认勾选、填包名)+ 条件还原按钮。
3. **排除重复的根文件夹** — 勾选框,默认开。
4. **已存在时** — 下拉,默认「询问」。
5. **密码** — 文本框 + 「显示密码」勾选框(`SecureField`/`TextField` 切换);已知密码自动预填,默认隐藏。
6. **将解压到:`<解析后的绝对路径>`** — 常驻预览行,实时反映展开 `~`、归一 `../.` 后的真实落点。**最有效的一道防呆,所见即所得。**
7. **内联提示行**:
   - 「到文件夹」取消勾选/留空 → 黄色 `⚠︎ 文件将直接解压到该位置,可能覆盖同名文件`(非阻塞,`解压` 仍可用)。
   - 校验失败 → 红色具体原因(见 §校验)。
8. 底部按钮:`取消` / `解压`(主按钮,校验通过才可用)。

## 架构与组件

### ① `ExtractOptions`(ArchiveKit,纯值 + 纯解析)

新增值类型,承载对话框输出,并含**可单测的纯解析/校验**逻辑:

```swift
public struct ExtractOptions: Sendable {
    public var location: URL            // 容器目录
    public var subfolderEnabled: Bool
    public var subfolderName: String    // 勾选时的子文件夹名
    public var stripSingleTopDir: Bool  // 排除重复根目录
    public var overwriteMode: CollisionChoice // .ask 语义 → 见下
    public var password: String
}
```

- `CollisionChoice` 目前在 App 层(`ExtractionController.swift`)。为让 `ExtractOptions` 纯解析可复用,**下沉到 ArchiveKit**(或在 ArchiveKit 新增 `OverwritePolicy { case ask, numbered, deleteExisting }`,App 层 `CollisionChoice` 保留用于反应式框)。实现时二选一,倾向下沉 `OverwritePolicy` 到 ArchiveKit、App 层做映射,避免 App→ArchiveKit 反向依赖。
- 目标解析(纯函数,主产物,重点单测):
  ```
  resolveDestination(options, singleTopLevelDir?) -> Result<Destination, ArchiveError>
  Destination = { finalFolder: URL, dumpIntoExisting: Bool, stripTopDir: String? }
  ```
  规则:
  - `subfolderEnabled && !name.trimmed.isEmpty` → `finalFolder = location/name`,`dumpIntoExisting=false`,`stripTopDir = stripSingleTopDir ? singleTopLevelDir : nil`。
  - 否则(不建子文件夹)→ `finalFolder = location`,`dumpIntoExisting=true`,`stripTopDir=nil`(铺进容器时 strip 不适用)。

### ② 校验(纯函数 + UI 实时)

纯函数 `validate(options) -> [ExtractValidationError]`,UI 与 ArchiveKit 共用同一套规则:

- **解压位置**:展开 `~`、标准化路径后,必须是**已存在且可写的目录**;否则 `.locationNotADirectory` / `.locationNotWritable`。不自动创建深层缺失父目录。
- **到文件夹**(勾选且非空时):去首尾空白后,必须是**单一合法路径分量**——含 `/` 或 `:`、或等于 `.`/`..` → `.invalidSubfolderName`。
- UI:每条错误对应字段红框 + 底部红字;有任一错误则 `解压` 禁用。ArchiveKit `resolveDestination` 起点复校,非法抛 `ArchiveError.invalidDestination`(fail-fast 后备)。

### ③ 对话框视图 `ExtractOptionsView`(SevenZipApp)

- 纯 SwiftUI `.sheet`,输入 = 初始 `ExtractOptions`(默认值)+ 上下文(包名、`singleTopLevelDir?`、是否加密),回调 `onExtract(ExtractOptions)` / `onCancel`。
- 内部 `@State` 持有可编辑草稿;实时算「将解压到」预览与校验结果(调 ArchiveKit 纯函数)。
- 还原按钮:比较当前值与传入默认值,不等才显示。
- 视图不含解压逻辑,确认后把 `ExtractOptions` 交回 `App.swift` 走统一控制层。

### ④ 控制层统一(`ExtractionController` + `App.swift`)

- `ExtractionController.extract` 增加 `options: ExtractOptions` 参数(或重构签名),内部:
  - 用 `resolveDestination` 得到 `finalFolder / dumpIntoExisting / stripTopDir`。
  - `dumpIntoExisting=false` 且目标夹已存在 → 按 `overwriteMode` 处理:`ask`→ `resolveCollision` 回调(反应式框);`numbered`→ `ExtractionTarget.resolve` 带序号;`deleteExisting`→ 删除后解压。
  - `dumpIntoExisting=true` → 跳过文件夹级碰撞,直接 `7zz x -y` 铺入(靠 §字段⑦ 黄色警告告知)。
  - 调用统一原语 `runner.extract(archive:entries:singleTopLevelDir: stripTopDir, to: finalFolder, password:)`,进度回调不变。
- **一键路**:`extractAll()` / `extractSelected()` 构造默认 `ExtractOptions`(location=包所在目录, subfolder=on+包名, strip=on, overwrite=.ask, password=已知),复用同一 `extract`。行为与现状等价(回归基线)。
- **对话框路**:菜单/右键 → 弹 `ExtractOptionsView` → 用户确认 → 同一 `extract`。
- 密码错误(`wrongPassword`):对话框路重弹对话框 + 内联错误;一键路维持现有密码 sheet 重试逻辑。

### ⑤ 入口接线(`App.swift` / `TwoPaneBrowserView.swift`)

- 工具栏「解压全部」→ `Menu(primaryAction: extractAll)`,菜单项「解压到…(选项)」= 弹对话框(entries=全部)。
- 工具栏「解压选中」→ `Menu(primaryAction: { extractSelected(selection) })`,菜单项「解压选中到…」= 弹对话框(entries=选中)。
- `TwoPaneBrowserView` 右键「解压选中…」→ 走对话框路。

## 受影响文件

- 新增 `Sources/ArchiveKit/ExtractOptions.swift` — 值类型 + `resolveDestination` + `validate`(纯,重点单测)。
- 新增 `Sources/ArchiveKit/OverwritePolicy.swift`(或并入上一文件)— 覆盖策略枚举。
- 新增 `Sources/SevenZipApp/ExtractOptionsView.swift` — 对话框视图。
- `Sources/SevenZipApp/ExtractionController.swift` — 接受 `ExtractOptions`,统一目标/碰撞;`CollisionChoice` 与 `OverwritePolicy` 映射。
- `Sources/SevenZipApp/App.swift` — 分体菜单入口、对话框状态、对话框路的密码错误重弹、默认 `ExtractOptions` 构造。
- `Sources/SevenZipApp/TwoPaneBrowserView.swift` — 右键接到对话框路。
- `Sources/ArchiveKit/ArchiveError.swift` — 新增 `invalidDestination`。
- `project.yml` / XcodeGen — 纳入新文件(若非自动 glob)。

## 测试策略

- **纯逻辑单测**(`Tests/ArchiveKitTests/ExtractOptionsTests.swift`),覆盖「乱填」矩阵:
  - `resolveDestination`:勾选子文件夹 + strip 开/关 + `singleTopLevelDir` 有/无;不勾选(dump)时 finalFolder=容器且 stripTopDir=nil。
  - `validate`:位置不存在 / 不可写 / 非目录;子文件夹名含 `/`、`:`、`.`、`..`、前后空白;`~` 展开与 `../` 归一后的落点断言。
- **回归基线**:构造默认 `ExtractOptions` 后 `resolveDestination` 的目标应与旧 `ExtractionController` 自动定目标一致(单顶层目录去重、带序号等)。
- 对话框视图、分体菜单、还原按钮、密码重弹、预览行 = UI 接线,靠 `make build` + 手动 GUI 验证。

## 非目标(本次不做)

- 压缩 / 创建归档(C 类别)——独立 spec。
- 文件级 `-ao*` 覆盖策略;路径模式(完整/无路径);7z 参数全量选单;「高级」折叠区。
- 多语言/本地化(沿用现有中文硬编码风格)。

## 计划偏移 / 待同步(执行中回填)

_(此节留给实现阶段:若出现值得用户注意的选择或与本设计的偏移,记录于此。)_

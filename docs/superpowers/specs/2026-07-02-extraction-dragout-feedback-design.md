# 解压交互闭环 + 健壮性/反馈 — 设计文档

日期:2026-07-02

## 背景与目标

浏览/解压体验还差最后一块拼图,外加几个之前 deferred 的正确性/反馈缺口:

- **A. 拖出到 Finder**:从压缩包把文件/目录直接拖到访达完成解压(brainstorming 里"第二批"的 ③,与已完成的单文件预览 ④ 并列)。
- **B. 健壮性/反馈**:
  - **b1**(真 bug):"解压选中"单个条目、且压缩包是单顶层目录结构时会**双层嵌套**(`parent/project/project/…`)。现有双层嵌套修复只覆盖了"解压全部",`selectedPaths` 分支走的是普通 `extract` 而非 `extractAll` 的 temp+move。
  - **b2**:解压成功后无任何反馈。
  - **b3**:解压失败无错误提示;解压时密码错误无提示。

本批不做:多选整批拖出;压缩功能(C);点击解压的 Windows 7-Zip 式**选项对话框**(独立的下一个 spec,会复用本批成果——见 memory `extraction-compression-gui-options-vision`)。

## 关键决策(已与用户确认)

- **拖出机制**:惰性——SwiftUI `.onDrag` 提供 `NSItemProvider` 的**惰性文件表示**(`registerFileRepresentation`),Finder 真来取时才解压,复用 `PreviewService.url(for:)`。
- **b1 产出**:剔掉单顶层目录前缀,与"解压全部"一致(目标夹 `project/` 内部直接是 `src/a.txt`)。
- **成功反馈可配置**(新增 Settings ⌘,):`打开 Finder / 应用内提示(提示上带"打开 Finder"按钮)/ 不提示`,默认打开 Finder。
- **错误反馈**:失败弹 alert;解压时密码错误重弹密码框并显示"密码错误"。

## 架构与组件

### ① 统一解压原语(修 b1 + DRY)

把 `SevenZipRunner.extractAll(archive:singleTopLevelDir:to:password:)` 泛化为:

```swift
public func extract(archive: URL, entries: [String]?, singleTopLevelDir: String?,
                    to finalFolder: URL, password: String?) throws
```

- `entries == nil` → 全部;否则只解压选中的子集。
- **共用同一套 temp+move 逻辑**:`singleTopLevelDir != nil` 时,`7z x` 到临时目录(与 `finalFolder` 同卷,便于 rename),再 `moveItem(temp/<topDir> → finalFolder)`,剥掉重复前缀;`== nil` 时直接 `7z x -o<finalFolder>`(选中子集不会双 nest)。
- 因为压缩包若有单顶层目录,则**所有条目**(含任何选中子集)必在其下,`temp/<topDir>` 恒存在,逻辑对子集天然成立。

保留原 `public func extract(archive:entries:to:password:)`(纯 `7z x -o`,无 move)供拖出/预览等"直接解到指定目录"的场景;新方法用于面向用户的"解压到目标夹"。`extractAll` 若无其他调用点则并入新方法。

`ExtractionController.extract(...)`:删掉"selected 走普通 extract / all 走 extractAll"的分支,**统一**调用
`runner.extract(archive:, entries: selectedPaths, singleTopLevelDir:, to: dest, password:)`。

### ② 拖出到 Finder(惰性)

`TwoPaneBrowserView` 的表格"名称"列单元加 `.onDrag { makeDragProvider(node) }`:

```swift
private func makeDragProvider(_ node: ArchiveNode) -> NSItemProvider {
    let provider = NSItemProvider()
    let typeID = UTType.item.identifier   // 具体 UTI 由 node 扩展名细化,目录用 .folder
    provider.suggestedName = node.name
    provider.registerFileRepresentation(forTypeIdentifier: typeID,
                                        fileOptions: [], visibility: .all) { completion in
        Task { @MainActor in
            do {
                let url = try await previewService.url(for: node)  // 惰性解压(文件或目录子树)
                completion(url, false, nil)                        // false = 不转移所有权,Finder 复制
            } catch {
                completion(nil, false, error)
            }
        }
        return nil
    }
    return provider
}
```

- 复用 `PreviewService.url(for:)`:文件解出单文件,目录解出整棵子树;Finder 按叶子名落地(`src/` → 落点/`src`,`a.txt` → 落点/`a.txt`),天然无前缀问题。
- 复用 PreviewService 的 per-window 临时目录 + 缓存 + 关窗清理;密码已同步。
- MVP 逐行拖(拖谁出谁)。多选整批拖为非目标。

### ③ 成功反馈 + Settings(新增)

- 新增 `AppSettings`(或直接 `@AppStorage`)+ 一个枚举:

```swift
enum PostExtractAction: String, CaseIterable { case revealInFinder, notify, none }
// @AppStorage("postExtractAction") 默认 .revealInFinder
```

- 新增 SwiftUI `Settings` 场景(⌘,)+ `SettingsView`:一个 Picker「解压完成后」= 打开 Finder / 应用内提示 / 不提示。
- `runExtraction` 成功拿到目标 `URL` 后,按设置执行:
  - `.revealInFinder` → `NSWorkspace.shared.activateFileViewerSelecting([dest])`。
  - `.notify` → 在 ArchiveWindow 上显示一个短暂自动消失的 toast:「已解压到 <名称>」+ 一个「打开 Finder」按钮(点击 = activateFileViewerSelecting)。
  - `.none` → 不做。
- Toast:轻量 overlay(`@State toast: ToastState?` + 自动消失计时),单文件 `Toast.swift` 小组件。

### ④ 错误 / 密码反馈

`runExtraction` 的 `catch` 不再吞错:

- `catch ArchiveError.wrongPassword`(`runner.extract` 在密码错时抛此):重新 `showPasswordSheet = true`,并把一条"密码错误,请重试"传给 `PasswordPromptView` 显示。
- `catch is CancellationError`:静默(用户取消碰撞对话框)。
- 其他 `catch`:设置 `extractError = "\(error)"`,弹 `.alert` 展示。

`PasswordPromptView` 增加可选 `errorMessage: String?`,非空时在密码框上方以 `.foregroundStyle(.red)` 显示。该视图现同时用于**打开时**解锁与**解压时**密码错误重试,错误信息由调用方注入。

## 受影响文件

- `Sources/ArchiveKit/SevenZipRunner.swift` — 泛化 `extract(entries:singleTopLevelDir:…)`。
- `Sources/SevenZipApp/ExtractionController.swift` — 统一走新方法。
- `Sources/SevenZipApp/TwoPaneBrowserView.swift` — 行 `.onDrag` 拖出。
- `Sources/SevenZipApp/App.swift` — Settings 场景、`runExtraction` 反馈/错误、toast 状态、alert。
- `Sources/SevenZipApp/PasswordPromptView.swift` — 错误提示参数。
- 新增:`Sources/SevenZipApp/SettingsView.swift`、`Sources/SevenZipApp/Toast.swift`(轻量提示)。

## 测试策略

- **b1 集成测试**(`Tests/ArchiveKitTests/SevenZipRunnerTests.swift`):用一个单顶层目录的 fixture 压缩包,调用统一 `extract(entries: [子集], singleTopLevelDir: "top", to: dest)`,断言结果落在 `dest/<子集相对路径>` 且**不存在** `dest/top/…`(无双层嵌套)。若测试环境无可用 7zz 二进制,则降级为手动验证并在计划中说明。
- 纯逻辑不变(`ExtractionTarget` 已有测试)。
- 拖出、Settings、toast、alert、密码重弹 = UI 接线,靠 `make build` + 手动 GUI 验证(拖文件/目录到访达;三种反馈;失败与密码错误路径)。

## 非目标(本次不做)

- 多选整批拖出(SwiftUI Table 支持弱)。
- 点击解压的选项对话框(Windows 7-Zip 式)—— 独立的下一个 spec。
- 压缩 / 创建(C);7z 参数全量图形化选单。

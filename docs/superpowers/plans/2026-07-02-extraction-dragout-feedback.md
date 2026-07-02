# 解压交互闭环 + 健壮性/反馈 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 YA Unarchiver 补齐"从压缩包拖文件到 Finder 解压"能力,修复"解压选中"单顶层目录时的双层嵌套 bug,并为解压加上可配置的成功反馈与错误/密码反馈。

**Architecture:** 先把 `SevenZipRunner` 的解压能力统一成一个带 `singleTopLevelDir` 的原语(temp+move 剔前缀,同时服务"解压全部"与"解压选中"),`ExtractionController` 统一走它。UI 层新增行 `.onDrag` 惰性拖出(复用 `PreviewService.url(for:)`)、`Settings` 场景 + `@AppStorage` 驱动的解压完成反馈(打开 Finder / toast / 不提示),以及 `runExtraction` 不再吞错(失败弹 alert、密码错误重弹带错误提示的密码框)。

**Tech Stack:** Swift 6 / SwiftUI (macOS 14) / AppKit interop (`NSItemProvider`, `NSWorkspace`) / XCTest 集成测试(依赖系统 `/opt/homebrew/bin/7z`) / XcodeGen + xcodebuild(`make build` / `make test`)。

## Global Constraints

- 部署目标 macOS 14.0;Swift 6;ad-hoc 签名(不改签名配置)。
- 打包的 `Resources/7zz` 二进制**不入库**(gitignored),不在本批任何 commit 中出现。
- 面向用户的 UI 文案用中文;代码注释用英文(沿用现有文件的既有注释语言)。
- 构建:`make build`。测试:`make test`(经 xcodebuild + Xcode 工具链)。集成测试需要本机存在 `/opt/homebrew/bin/7z`;缺失时相关测试会因启动失败而报错,此时降级为在计划说明处记录并手动验证。
- 分支:`feat/dragout-feedback`(已建、已 push)。
- 保留 `SevenZipRunner.extract(archive:entries:to:password:)`(纯 `7z x -o`,无 move)——供 `PreviewService` / 拖出使用;新增的 5 参方法仅用于"解压到目标夹"。

---

## File Structure

- `Sources/ArchiveKit/SevenZipRunner.swift` — 用 5 参 `extract(archive:entries:singleTopLevelDir:to:password:)` 取代 `extractAll`;保留原 4 参 `extract`。
- `Sources/SevenZipApp/ExtractionController.swift` — 删掉 selected/all 分支,统一调新方法。
- `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` — 3 个 `extractAll` 测试改调新方法 + 新增 b1 子集剔前缀测试。
- `Sources/SevenZipApp/TwoPaneBrowserView.swift` — "名称"列单元加 `.onDrag`,新增 `makeDragProvider(_:)`。
- `Sources/SevenZipApp/PostExtractAction.swift`(新建) — 反馈偏好枚举。
- `Sources/SevenZipApp/SettingsView.swift`(新建) — ⌘, 设置面板。
- `Sources/SevenZipApp/Toast.swift`(新建) — 轻量提示组件 + `ToastState`。
- `Sources/SevenZipApp/App.swift` — 加 `Settings` 场景;`ArchiveWindow` 加 toast/alert/密码上下文状态;`runExtraction` 成功按偏好反馈、失败不吞错。
- `Sources/SevenZipApp/PasswordPromptView.swift` — 新增可选 `errorMessage`。

---

## Task 1: 统一解压原语 + 修 b1 双层嵌套

**Files:**
- Modify: `Sources/ArchiveKit/SevenZipRunner.swift:89-109`(替换 `extractAll`)
- Modify: `Sources/SevenZipApp/ExtractionController.swift:42-52`
- Test: `Tests/ArchiveKitTests/SevenZipRunnerTests.swift:61-83`(改 3 个测试 + 加 1 个)

**Interfaces:**
- Consumes: 现有 4 参 `public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?) throws`;`ExtractionTarget.hasSingleTopLevelDirectory(_ entries: [ArchiveEntry]) -> String?`;测试夹具 `TestArchives.singleTopDirArchive()`(内含 `project/src/a.txt`)、`TestArchives.twoFileArchive()`(`f1.txt`/`f2.txt`)、`TestArchives.makeTempDir()`。
- Produces: `public func extract(archive: URL, entries: [String]?, singleTopLevelDir: String?, to finalFolder: URL, password: String?) throws`(供 `ExtractionController` 调用)。`extractAll` 被移除。

- [ ] **Step 1: 改写/新增测试**

将 `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` 中现有的三个 `extractAll` 测试(`test_extractAll_single_top_dir_does_not_double_nest` / `test_extractAll_single_top_dir_into_numbered_folder` / `test_extractAll_wrap_case_places_entries_under_final_folder`)整体替换为下面四个测试(前三个改调新签名,最后一个是新增的 b1 子集测试):

```swift
    func test_extract_single_top_dir_does_not_double_nest() throws {
        let archive = try TestArchives.singleTopDirArchive()          // entries under project/
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project")
        try runner.extract(archive: archive, entries: nil, singleTopLevelDir: "project",
                           to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: finalFolder.appendingPathComponent("project").path),
                       "must not double-nest as project/project")
    }

    func test_extract_single_top_dir_into_numbered_folder() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project 2")
        try runner.extract(archive: archive, entries: nil, singleTopLevelDir: "project",
                           to: finalFolder, password: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
    }

    func test_extract_wrap_case_places_entries_under_final_folder() throws {
        let archive = try TestArchives.twoFileArchive()
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("bundle")
        try runner.extract(archive: archive, entries: nil, singleTopLevelDir: nil,
                           to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("f1.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("f2.txt").path))
    }

    func test_extract_selected_subset_under_single_top_dir_strips_prefix() throws {
        // b1 regression: selecting a single entry inside a single-top-dir archive
        // must land at finalFolder/<relative-to-topdir>, NOT finalFolder/project/…
        let archive = try TestArchives.singleTopDirArchive()          // project/src/a.txt
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project")
        try runner.extract(archive: archive, entries: ["project/src/a.txt"],
                           singleTopLevelDir: "project", to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: finalFolder.appendingPathComponent("project").path),
                       "selected-subset extraction must not double-nest as project/project")
    }
```

- [ ] **Step 2: 跑测试确认失败(编译错误)**

Run: `make test`
Expected: 编译失败 —— `value of type 'SevenZipRunner' has no member 'extract'` 匹配到 5 参签名不存在(以及 `extractAll` 引用消失导致的相关错误)。

- [ ] **Step 3: 在 SevenZipRunner 里用 5 参 `extract` 取代 `extractAll`**

把 `Sources/ArchiveKit/SevenZipRunner.swift` 中现有的 `extractAll(archive:singleTopLevelDir:to:password:)` 方法(第 89–109 行,含其上方的文档注释块)整体替换为:

```swift
    /// Extracts (all of, or a selected subset of) an archive so that `finalFolder`
    /// directly contains the result, with no `foo/foo` double-nesting.
    ///
    /// - `entries == nil` extracts everything; a non-nil `entries` extracts only those
    ///   archive-internal paths.
    /// - When `singleTopLevelDir` is non-nil, the archive's lone top-level directory is a
    ///   redundant prefix: extract into a temp dir on the SAME volume as `finalFolder`
    ///   (so the move is a cheap rename), then move `temp/<singleTopLevelDir>` into place,
    ///   stripping the prefix. Because every entry (and thus any selected subset) lives
    ///   under that lone top dir, `temp/<singleTopLevelDir>` always exists.
    /// - When `singleTopLevelDir` is nil, entries are placed under `finalFolder` directly.
    ///
    /// `finalFolder` must not already exist (the caller resolves collisions first).
    public func extract(archive: URL, entries: [String]?, singleTopLevelDir: String?,
                        to finalFolder: URL, password: String?) throws {
        let fm = FileManager.default
        guard let topDir = singleTopLevelDir else {
            try extract(archive: archive, entries: entries, to: finalFolder, password: password)
            return
        }
        let parent = finalFolder.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".7zip-swiftui-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try extract(archive: archive, entries: entries, to: temp, password: password)
        try fm.moveItem(at: temp.appendingPathComponent(topDir), to: finalFolder)
    }
```

- [ ] **Step 4: 更新 ExtractionController 统一走新方法**

在 `Sources/SevenZipApp/ExtractionController.swift` 中,把第 42–52 行的这段:

```swift
        let runner = self.runner
        let dest = destination
        let singleTopDir = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        try await Task.detached {
            if let selectedPaths {
                try runner.extract(archive: archive, entries: selectedPaths, to: dest, password: password)
            } else {
                try runner.extractAll(archive: archive, singleTopLevelDir: singleTopDir, to: dest, password: password)
            }
        }.value
        return destination
```

替换为:

```swift
        let runner = self.runner
        let dest = destination
        let singleTopDir = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        try await Task.detached {
            try runner.extract(archive: archive, entries: selectedPaths,
                               singleTopLevelDir: singleTopDir, to: dest, password: password)
        }.value
        return destination
```

- [ ] **Step 5: 跑测试与构建确认通过**

Run: `make test`
Expected: PASS —— 全部 ArchiveKit 单测通过(含新增的 `test_extract_selected_subset_under_single_top_dir_strips_prefix`)。

Run: `make build`
Expected: 构建成功,无错误(确认 `ExtractionController` 改动后 app target 仍能编译)。

- [ ] **Step 6: 提交**

```bash
git add Sources/ArchiveKit/SevenZipRunner.swift Sources/SevenZipApp/ExtractionController.swift Tests/ArchiveKitTests/SevenZipRunnerTests.swift
git commit -m "fix(extract): unify extract primitive with singleTopLevelDir, fix selected-subset double-nest

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 拖出到 Finder(惰性)

**Files:**
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift`(第 127–134 行"名称"列单元 + 新增私有方法)

**Interfaces:**
- Consumes: `previewService.url(for node: ArchiveNode) async throws -> URL`(已存在,惰性解压单文件或目录子树到 per-window 临时目录并缓存);`ArchiveNode`(`id: String` 全路径、`name: String`、`isDirectory: Bool`);已 `import UniformTypeIdentifiers` / `import AppKit`。
- Produces: 无对外接口;仅给表格行添加拖出行为。

- [ ] **Step 1: 给"名称"列单元加 `.onDrag`**

在 `Sources/SevenZipApp/TwoPaneBrowserView.swift` 中,把 `fileTable` 里的"名称"列(第 127–134 行)由:

```swift
            TableColumn("名称") { (n: ArchiveNode) in
                HStack(spacing: 6) {
                    Image(nsImage: Self.icon(for: n))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(n.name)
                }
            }
```

改为:

```swift
            TableColumn("名称") { (n: ArchiveNode) in
                HStack(spacing: 6) {
                    Image(nsImage: Self.icon(for: n))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(n.name)
                }
                .onDrag { makeDragProvider(n) }
            }
```

- [ ] **Step 2: 新增 `makeDragProvider(_:)`**

在 `TwoPaneBrowserView` 内(例如紧邻 `singleSelectedFile` 计算属性之后,`private static func find` 之前)新增:

```swift
    // MARK: - Drag out to Finder

    /// Builds a lazy file-promise provider: Finder only triggers extraction when the
    /// user actually drops. Reuses PreviewService's on-demand extraction + per-window
    /// temp dir + cache. A file extracts to a single file; a directory extracts its
    /// whole subtree. Finder lands the item by its leaf name, so there is no prefix issue.
    private func makeDragProvider(_ node: ArchiveNode) -> NSItemProvider {
        let provider = NSItemProvider()
        let type: UTType = node.isDirectory
            ? .folder
            : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
        provider.suggestedName = node.name
        let previewService = self.previewService
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                             fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let url = try await previewService.url(for: node)
                    completion(url, false, nil)   // false = coordinated copy, keep our temp file
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
```

- [ ] **Step 3: 构建**

Run: `make build`
Expected: 构建成功,无错误、无 Swift 6 并发告警(`previewService` 已在闭包外 `let` 捕获,`Task { @MainActor in }` 内访问 MainActor 隔离的 PreviewService)。

- [ ] **Step 4: 手动验证(GUI)**

Run: `make run`

手动确认:
1. 打开一个含目录结构的压缩包(可用一个真实 `.zip`/`.7z`)。
2. 从右侧列表把一个**文件**行拖到 Finder 窗口/桌面 → 落地为该文件(叶子名),内容正确。
3. 拖一个**目录**行到 Finder → 落地为该目录整棵子树。
4. 拖动时不阻塞主线程(拖放释放后才解压)。

- [ ] **Step 5: 提交**

```bash
git add Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(browser): drag files/folders out of archive to Finder (lazy extraction)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Settings 场景 + 可配置成功反馈

**Files:**
- Create: `Sources/SevenZipApp/PostExtractAction.swift`
- Create: `Sources/SevenZipApp/SettingsView.swift`
- Create: `Sources/SevenZipApp/Toast.swift`
- Modify: `Sources/SevenZipApp/App.swift`(`SevenZipSwiftUIApp.body` 加 `Settings`;`ArchiveWindow` 加状态 + overlay;`runExtraction` 成功分支)

**Interfaces:**
- Consumes: `ExtractionController.extract(...) async throws -> URL`(返回最终目标目录);`NSWorkspace.shared.activateFileViewerSelecting(_:)`。
- Produces:
  - `enum PostExtractAction: String, CaseIterable, Identifiable`,cases `revealInFinder` / `notify` / `none`,`var label: String`。`@AppStorage("postExtractAction")` 默认 `.revealInFinder`。
  - `struct ToastState: Identifiable { let id = UUID(); let message: String; let folderURL: URL }`
  - `struct Toast: View`(`message: String`, `onOpenFinder: () -> Void`)。
  - `struct SettingsView: View`。
  - `ArchiveWindow` 新增 `showToast(message:folderURL:)` 供后续任务复用。

- [ ] **Step 1: 新建 `PostExtractAction.swift`**

创建 `Sources/SevenZipApp/PostExtractAction.swift`:

```swift
import Foundation

/// What to do after a successful extraction. Persisted via @AppStorage; user-configurable
/// in the Settings scene (⌘,). Default is `.revealInFinder`.
enum PostExtractAction: String, CaseIterable, Identifiable {
    case revealInFinder
    case notify
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .revealInFinder: return "打开 Finder"
        case .notify:         return "应用内提示"
        case .none:           return "不提示"
        }
    }
}
```

- [ ] **Step 2: 新建 `SettingsView.swift`**

创建 `Sources/SevenZipApp/SettingsView.swift`:

```swift
import SwiftUI

/// The ⌘, settings pane. Currently one preference: what happens after an extraction.
struct SettingsView: View {
    @AppStorage("postExtractAction") private var postExtractAction: PostExtractAction = .revealInFinder

    var body: some View {
        Form {
            Picker("解压完成后", selection: $postExtractAction) {
                ForEach(PostExtractAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .pickerStyle(.inline)
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View { SettingsView() }
}
```

- [ ] **Step 3: 新建 `Toast.swift`**

创建 `Sources/SevenZipApp/Toast.swift`:

```swift
import SwiftUI

/// One transient success toast: a message plus an "打开 Finder" action. Identity lets the
/// owning view cancel a stale auto-dismiss when a newer toast replaces it.
struct ToastState: Identifiable {
    let id = UUID()
    let message: String
    let folderURL: URL
}

/// Lightweight capsule overlay shown at the bottom of the archive window.
struct Toast: View {
    let message: String
    let onOpenFinder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message)
            Button("打开 Finder", action: onOpenFinder)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8)
    }
}
```

- [ ] **Step 4: 在 App 场景里加 `Settings`**

在 `Sources/SevenZipApp/App.swift` 的 `SevenZipSwiftUIApp.body` 中,`Window("关于 YA Unarchiver", id: "about") { … }.windowResizability(.contentSize)` 之后、`body` 闭合 `}` 之前,追加:

```swift
        Settings {
            SettingsView()
        }
```

- [ ] **Step 5: 给 ArchiveWindow 加反馈状态与 overlay**

在 `Sources/SevenZipApp/App.swift` 的 `ArchiveWindow` 里,新增状态属性(放在 `@State private var isExtracting = false` 之后):

```swift
    @State private var toast: ToastState?
    @AppStorage("postExtractAction") private var postExtractAction: PostExtractAction = .revealInFinder
```

在 `body` 中,把当前的:

```swift
        content
            .frame(minWidth: 720, minHeight: 460)
            .navigationTitle(archiveURL.lastPathComponent)
```

改为(加一个 bottom overlay 承载 toast):

```swift
        content
            .frame(minWidth: 720, minHeight: 460)
            .navigationTitle(archiveURL.lastPathComponent)
            .overlay(alignment: .bottom) {
                if let toast {
                    Toast(message: toast.message,
                          onOpenFinder: { NSWorkspace.shared.activateFileViewerSelecting([toast.folderURL]) })
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
```

并在 `ArchiveWindow` 内新增 `showToast`(放在 `finishCollision` 之后):

```swift
    private func showToast(message: String, folderURL: URL) {
        let state = ToastState(message: message, folderURL: folderURL)
        withAnimation { toast = state }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 4s auto-dismiss
            if toast?.id == state.id { withAnimation { toast = nil } }
        }
    }
```

- [ ] **Step 6: `runExtraction` 成功分支按偏好反馈**

在 `Sources/SevenZipApp/App.swift` 中,把当前的 `runExtraction`:

```swift
    private func runExtraction(selectedPaths: [String]?) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false }
            do {
                _ = try await controller.extract(
                    archive: archiveURL,
                    entries: model.lastEntries,
                    selectedPaths: selectedPaths,
                    password: model.password,
                    resolveCollision: { url in
                        await withCheckedContinuation { cont in
                            collisionContinuation = cont
                            collisionURL = url
                        }
                    }
                )
            } catch { /* CancellationError or extraction failure — surfaced via alert in a later polish pass */ }
        }
    }
```

替换为(成功后按 `postExtractAction` 反馈;错误处理留待 Task 4):

```swift
    private func runExtraction(selectedPaths: [String]?) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false }
            do {
                let dest = try await controller.extract(
                    archive: archiveURL,
                    entries: model.lastEntries,
                    selectedPaths: selectedPaths,
                    password: model.password,
                    resolveCollision: { url in
                        await withCheckedContinuation { cont in
                            collisionContinuation = cont
                            collisionURL = url
                        }
                    }
                )
                switch postExtractAction {
                case .revealInFinder:
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                case .notify:
                    showToast(message: "已解压到 \(dest.lastPathComponent)", folderURL: dest)
                case .none:
                    break
                }
            } catch { /* error/password handling added in Task 4 */ }
        }
    }
```

- [ ] **Step 7: 构建**

Run: `make build`
Expected: 构建成功,无错误。

- [ ] **Step 8: 手动验证(GUI)**

Run: `make run`

手动确认:
1. ⌘, 打开设置面板,「解压完成后」Picker 有三项:打开 Finder / 应用内提示 / 不提示;默认选中「打开 Finder」。
2. 选「打开 Finder」→ 解压后自动在 Finder 中选中目标夹。
3. 选「应用内提示」→ 解压后窗口底部出现 toast「已解压到 …」,点「打开 Finder」按钮能在 Finder 选中目标夹,约 4 秒后自动消失。
4. 选「不提示」→ 解压后无任何反馈。

- [ ] **Step 9: 提交**

```bash
git add Sources/SevenZipApp/PostExtractAction.swift Sources/SevenZipApp/SettingsView.swift Sources/SevenZipApp/Toast.swift Sources/SevenZipApp/App.swift
git commit -m "feat(extract): configurable post-extraction feedback (reveal in Finder / toast / none)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 错误 / 密码反馈

**Files:**
- Modify: `Sources/SevenZipApp/PasswordPromptView.swift`(新增可选 `errorMessage`)
- Modify: `Sources/SevenZipApp/App.swift`(`ArchiveWindow`:密码上下文/错误状态、sheet 接线、alert、`runExtraction` 的 `catch`)

**Interfaces:**
- Consumes: `ArchiveError.wrongPassword`(`SevenZipRunner.extract` 密码错误时抛出);`ArchiveViewModel.password: String?`(`private(set)`,不可从视图写)、`model.load(password:)`;`previewService.password`(可写)。
- Produces: `PasswordPromptView` 新增可选参 `errorMessage: String?`(默认 nil,非空时红字显示于密码框上方)。

- [ ] **Step 1: `PasswordPromptView` 增加 `errorMessage`**

把 `Sources/SevenZipApp/PasswordPromptView.swift` 整体替换为:

```swift
import SwiftUI

struct PasswordPromptView: View {
    @Binding var password: String
    var errorMessage: String? = nil
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("此压缩包已加密").font(.headline)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(onSubmit)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("打开", action: onSubmit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 2: ArchiveWindow 新增密码上下文与错误状态**

在 `Sources/SevenZipApp/App.swift` 的 `ArchiveWindow` 里,`isExtracting` 相关状态附近新增:

```swift
    @State private var passwordError: String?
    @State private var extractError: String?
    @State private var extractPassword: String?   // password confirmed for extraction, overrides model.password
    private enum PasswordContext { case unlock, retryExtraction(selectedPaths: [String]?) }
    @State private var passwordContext: PasswordContext = .unlock
```

- [ ] **Step 3: sheet 按上下文分派 + 新增错误 alert**

在 `body` 中,把当前的密码 sheet:

```swift
            .sheet(isPresented: $showPasswordSheet) {
                PasswordPromptView(
                    password: $passwordDraft,
                    onSubmit: { showPasswordSheet = false; model.load(password: passwordDraft) },
                    onCancel: { showPasswordSheet = false }
                )
            }
```

替换为:

```swift
            .sheet(isPresented: $showPasswordSheet) {
                PasswordPromptView(
                    password: $passwordDraft,
                    errorMessage: passwordError,
                    onSubmit: {
                        showPasswordSheet = false
                        let entered = passwordDraft
                        passwordError = nil
                        switch passwordContext {
                        case .unlock:
                            model.load(password: entered)
                        case .retryExtraction(let paths):
                            extractPassword = entered
                            previewService.password = entered
                            runExtraction(selectedPaths: paths)
                        }
                        passwordContext = .unlock
                    },
                    onCancel: {
                        showPasswordSheet = false
                        passwordError = nil
                        passwordContext = .unlock
                    }
                )
            }
```

再在其后(例如紧跟 `.confirmationDialog(...)` 之后)追加一个错误 alert:

```swift
            .alert("解压失败", isPresented: Binding(get: { extractError != nil }, set: { if !$0 { extractError = nil } })) {
                Button("好", role: .cancel) { extractError = nil }
            } message: {
                Text(extractError ?? "")
            }
```

- [ ] **Step 4: `runExtraction` 使用 extractPassword + 不吞错**

在 `Sources/SevenZipApp/App.swift` 中,把 Task 3 产出的 `runExtraction` 替换为下面的最终版本(密码优先用已确认的 `extractPassword`;`catch` 区分取消/密码错/其它):

```swift
    private func runExtraction(selectedPaths: [String]?) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false }
            do {
                let dest = try await controller.extract(
                    archive: archiveURL,
                    entries: model.lastEntries,
                    selectedPaths: selectedPaths,
                    password: extractPassword ?? model.password,
                    resolveCollision: { url in
                        await withCheckedContinuation { cont in
                            collisionContinuation = cont
                            collisionURL = url
                        }
                    }
                )
                switch postExtractAction {
                case .revealInFinder:
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                case .notify:
                    showToast(message: "已解压到 \(dest.lastPathComponent)", folderURL: dest)
                case .none:
                    break
                }
            } catch is CancellationError {
                // user cancelled the collision dialog — stay silent
            } catch ArchiveError.wrongPassword {
                passwordDraft = ""
                passwordError = "密码错误，请重试"
                passwordContext = .retryExtraction(selectedPaths: selectedPaths)
                showPasswordSheet = true
            } catch {
                extractError = "\(error)"
            }
        }
    }
```

- [ ] **Step 5: 构建**

Run: `make build`
Expected: 构建成功,无错误。

- [ ] **Step 6: 手动验证(GUI)**

Run: `make run`

手动确认:
1. **成功路径不回归**:普通压缩包解压仍按 Task 3 的偏好反馈。
2. **取消碰撞**:目标夹已存在时弹碰撞对话框,点「取消」→ 无 alert、无提示(静默)。
3. **数据加密、解压时密码错**:打开一个仅数据加密(列目录不需密码、解压需密码)的压缩包,点解压 → 弹密码框;先输错密码 → 密码框再次弹出并显示红字「密码错误，请重试」;再输对 → 解压成功并给出成功反馈。
4. **其它失败**:制造一个损坏/不可解压的情形 → 弹「解压失败」alert 显示错误信息。

- [ ] **Step 7: 提交**

```bash
git add Sources/SevenZipApp/PasswordPromptView.swift Sources/SevenZipApp/App.swift
git commit -m "feat(extract): surface extraction errors and wrong-password retry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- ① 统一解压原语 + b1 → Task 1(新 5 参 `extract`、temp+move 剔前缀、`ExtractionController` 统一、b1 集成测试)。✅
- ② 拖出到 Finder(惰性,复用 `PreviewService.url(for:)`)→ Task 2。✅
- ③ 成功反馈可配置 + Settings + toast → Task 3。✅
- ④ 错误/密码反馈(alert、密码重弹带错误、`PasswordPromptView.errorMessage`)→ Task 4。✅
- spec §测试策略:b1 集成测试在 Task 1;拖出/Settings/toast/alert/密码重弹 = `make build` + 手动 GUI 验证,已分列各任务的手动验证步骤。✅

**Type consistency:**
- `extract(archive:entries:singleTopLevelDir:to:password:)` 五参签名在 Task 1(定义)、测试、`ExtractionController` 调用处一致。
- `PostExtractAction` cases `revealInFinder/notify/none` + `label` 在 Task 3 定义,Task 3/4 的 `switch` 用法一致。
- `ToastState(message:folderURL:)`、`Toast(message:onOpenFinder:)`、`showToast(message:folderURL:)` 三处签名一致。
- `PasswordPromptView(password:errorMessage:onSubmit:onCancel:)` 在 Task 4 定义并在 sheet 处调用一致(`errorMessage` 有默认值,不破坏别处调用——本仓库仅此一处调用)。
- 密码回填:`model.password` 为 `private(set)` 不可从视图写,故引入 `extractPassword` 覆盖,`runExtraction` 用 `extractPassword ?? model.password`;retry 时同时同步 `previewService.password`。类型一致。

**Placeholder scan:** 无 TODO/TBD;每个改代码的步骤都给了完整代码块与预期输出。Task 3 的 `runExtraction` `catch` 注释「error/password handling added in Task 4」是有意的阶段占位,Task 4 Step 4 给出最终完整版本替换之。

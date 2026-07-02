# 解压进度条 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 解压期间显示进度条:默认按 7zz `-bb1` 逐条目输出计算真实百分比,吐不出计数时自动退化为 indeterminate 动画。

**Architecture:** `SevenZipRunner` 新增逐行流式读取,`extract` 增可选 `@Sendable` 进度回调(带 `-bb1`,不传回调走原快路径)。纯逻辑 `ExtractionProgress.totalEntryCount` 从条目清单求分母。`ExtractionController` 算总数、线程安全计数、marshal 回主线程。`ArchiveWindow` 用 `ExtractionProgressState` 驱动一个中央半透明遮罩卡片。

**Tech Stack:** Swift 6 / SwiftUI (macOS 14) / Foundation `Process`+`Pipe` 流式读 / XCTest(纯逻辑单测 + 真实 7zz 集成测试,依赖 `/opt/homebrew/bin/7z`) / XcodeGen + xcodebuild(`make build` / `make test`)。

## Global Constraints

- 部署目标 macOS 14.0;Swift 6 严格并发;ad-hoc 签名。
- 打包的 `Resources/7zz` 二进制**不入库**(gitignored),不在任何 commit 中出现。
- 面向用户的 UI 文案用中文(精确:「正在解压…」、「正在解压… N%」);代码注释用英文。
- 构建:`make build`。**新增源文件后需先 `xcodegen generate` 再 `make build`**(Makefile 仅在 `project.yml` 变更时重生成 `.xcodeproj`;源码按目录 glob,新文件要重生成工程才会纳入)。测试:`make test`(xcodebuild + Xcode 工具链;集成测试需本机 `/opt/homebrew/bin/7z`)。
- 分支:`feat/extraction-progress`(已建、已提交 spec)。
- **进度按文件条目计数**,非字节权重。**无取消按钮**。
- 保留 `extract` 的无回调快路径:回调默认 `nil` 时不加 `-bb1`,走原 `run`——`PreviewService`/拖出/预览不受影响。
- Commit message 结尾必须是:`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

- `Sources/ArchiveKit/ExtractionProgress.swift`(新建) — `totalEntryCount(entries:selectedPaths:)` 纯逻辑分母。
- `Sources/ArchiveKit/SevenZipRunner.swift` — `runStreaming` 逐行读、`isEntryLine` 纯判定、`extract` 两个重载加可选 `onEntryExtracted` 回调 + `-bb1`。
- `Sources/SevenZipApp/ExtractionController.swift` — `extract` 加 `onProgress` 回调、`ProgressCounter`、算 total、marshal。
- `Sources/SevenZipApp/ExtractionProgressOverlay.swift`(新建) — `ExtractionProgressState` 枚举 + 遮罩卡片视图。
- `Sources/SevenZipApp/App.swift` — `ArchiveWindow` 加 `progress` 状态、遮罩 overlay、`runExtraction` 接线。
- `Tests/ArchiveKitTests/ExtractionProgressTests.swift`(新建) — `totalEntryCount` 单测。
- `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` — 加 `isEntryLine` 单测 + `-bb1` 进度集成测试。

---

## Task 1: 分母纯逻辑 `ExtractionProgress.totalEntryCount`

**Files:**
- Create: `Sources/ArchiveKit/ExtractionProgress.swift`
- Test: `Tests/ArchiveKitTests/ExtractionProgressTests.swift`

**Interfaces:**
- Consumes: `ArchiveEntry`(`public let path: String`;public 成员 init `ArchiveEntry(path:size:packedSize:modified:isDirectory:isEncrypted:)`)。
- Produces: `public enum ExtractionProgress { public static func totalEntryCount(entries: [ArchiveEntry], selectedPaths: [String]?) -> Int }`。

- [ ] **Step 1: 写失败测试**

创建 `Tests/ArchiveKitTests/ExtractionProgressTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class ExtractionProgressTests: XCTestCase {
    private func entry(_ path: String, dir: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil, isDirectory: dir, isEncrypted: false)
    }

    func test_total_all_entries_when_no_selection() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("b.txt")]
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: nil), 3)
    }

    func test_total_selected_single_file() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("a/y.txt")]
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: ["a/x.txt"]), 1)
    }

    func test_total_selected_directory_includes_subtree() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("a/sub/y.txt"), entry("b.txt")]
        // a + a/x.txt + a/sub/y.txt = 3
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: ["a"]), 3)
    }

    func test_total_prefix_does_not_match_sibling() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("ab", dir: true), entry("ab/y.txt")]
        // selecting "a" must count a + a/x.txt only, NOT ab or ab/y.txt
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: ["a"]), 2)
    }

    func test_total_empty_selection_is_zero() {
        let entries = [entry("x.txt")]
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: []), 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败(编译错误)**

Run: `make test`
Expected: 编译失败 —— `cannot find 'ExtractionProgress' in scope`。

- [ ] **Step 3: 实现 `ExtractionProgress`**

创建 `Sources/ArchiveKit/ExtractionProgress.swift`:

```swift
import Foundation

/// Computes how many entries 7zz will emit an output line for during extraction,
/// used as the denominator for a real progress bar. Counting is by entry (files
/// and directories alike), matching `7zz x -bb1`, which logs one line per extracted
/// entry.
public enum ExtractionProgress {
    /// - Parameters:
    ///   - entries: the full archive listing.
    ///   - selectedPaths: nil extracts everything; otherwise only these archive-internal
    ///     paths and everything beneath them.
    /// - Returns: the number of entries that will be extracted. For a selection, an entry
    ///   counts when its path equals a selected path or is nested under it (prefix
    ///   `"<selected>/"`), so selecting `a` does not match a sibling `ab`.
    public static func totalEntryCount(entries: [ArchiveEntry], selectedPaths: [String]?) -> Int {
        guard let selectedPaths else { return entries.count }
        let selected = Set(selectedPaths)
        return entries.filter { entry in
            if selected.contains(entry.path) { return true }
            return selectedPaths.contains { entry.path.hasPrefix($0 + "/") }
        }.count
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `make test`
Expected: PASS —— 5 个新测试全绿。

- [ ] **Step 5: 提交**

```bash
git add Sources/ArchiveKit/ExtractionProgress.swift Tests/ArchiveKitTests/ExtractionProgressTests.swift
git commit -m "feat(progress): add ExtractionProgress.totalEntryCount denominator logic

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Runner 流式读取 + `extract` 进度回调

**Files:**
- Modify: `Sources/ArchiveKit/SevenZipRunner.swift`(加 `isEntryLine`、`runStreaming`;`extract` 两个重载加 `onEntryExtracted`)
- Test: `Tests/ArchiveKitTests/SevenZipRunnerTests.swift`(加 2 个测试)

**Interfaces:**
- Consumes: 现有 `private func run(_:) -> RunResult`、`struct RunResult { code; stdout; stderr }`、`ArchiveError`、fixture `TestArchives.twoFileArchive()`(`f1.txt`/`f2.txt`)、`TestArchives.makeTempDir()`。
- Produces:
  - `public static func isEntryLine(_ line: String) -> Bool`(判定一行是否 7zz 条目行,`- ` 前缀)。
  - `public func extract(archive:entries:to:password:onEntryExtracted:)`(4 参加第 5 个可选回调,默认 nil)。
  - `public func extract(archive:entries:singleTopLevelDir:to:password:onEntryExtracted:)`(5 参加第 6 个可选回调,默认 nil,透传)。

- [ ] **Step 1: 写失败测试**

在 `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` 的 `final class SevenZipRunnerTests` 内追加:

```swift
    func test_isEntryLine_matches_only_entry_lines() {
        XCTAssertTrue(SevenZipRunner.isEntryLine("- big/sub/f001.bin"))
        XCTAssertTrue(SevenZipRunner.isEntryLine("- big/"))
        XCTAssertFalse(SevenZipRunner.isEntryLine("Everything is Ok"))
        XCTAssertFalse(SevenZipRunner.isEntryLine("Extracting archive: /tmp/a.7z"))
        XCTAssertFalse(SevenZipRunner.isEntryLine("--"))
        XCTAssertFalse(SevenZipRunner.isEntryLine(""))
    }

    func test_extract_reports_per_entry_progress() throws {
        // Proves -bb1 streams per-entry lines through a Pipe (non-TTY), so the callback fires.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let archive = try TestArchives.twoFileArchive()     // f1.txt, f2.txt
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        let counter = Counter()
        try runner.extract(archive: archive, entries: nil, to: dest, password: nil,
                           onEntryExtracted: { counter.bump() })
        XCTAssertGreaterThanOrEqual(counter.count, 2, "should report at least one line per extracted file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f2.txt").path))
    }
```

- [ ] **Step 2: 跑测试确认失败(编译错误)**

Run: `make test`
Expected: 编译失败 —— `type 'SevenZipRunner' has no member 'isEntryLine'`,以及 `extract` 无 `onEntryExtracted:` 参数的 extra-argument 报错。

- [ ] **Step 3: 加 `isEntryLine` 与 `runStreaming`**

在 `Sources/ArchiveKit/SevenZipRunner.swift` 的 `run(_:)` 方法之后追加两个方法:

```swift
    /// True when a `7zz x -bb1` output line announces an extracted entry (file or dir).
    /// Entry lines look like `- some/path`; banner, `--`, and summary lines do not match.
    public static func isEntryLine(_ line: String) -> Bool {
        line.hasPrefix("- ")
    }

    /// Like `run`, but reads stdout incrementally and invokes `onLine` for each complete
    /// line as it arrives (used to stream `-bb1` per-entry progress). stderr is read to end
    /// afterwards for error classification, matching `run`.
    private func runStreaming(_ arguments: [String], onLine: @Sendable (String) -> Void) throws -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ArchiveError.binaryNotFound
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw ArchiveError.binaryNotFound
        }
        let outHandle = outPipe.fileHandleForReading
        var stdoutText = ""
        var buffer = Data()
        while true {
            let chunk = outHandle.availableData
            if chunk.isEmpty { break }   // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {   // 0x0A == '\n'
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                let line = String(decoding: lineData, as: UTF8.self)
                stdoutText += line + "\n"
                onLine(line)
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty {   // trailing line without newline
            let line = String(decoding: buffer, as: UTF8.self)
            stdoutText += line
            onLine(line)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            code: process.terminationStatus,
            stdout: stdoutText,
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
```

- [ ] **Step 4: 给两个 `extract` 重载加可选回调**

在 `Sources/ArchiveKit/SevenZipRunner.swift` 中,把现有 4 参 `extract`(第 70–87 行)替换为:

```swift
    public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?,
                        onEntryExtracted: (@Sendable () -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["x", "-bd", "-y", "-o\(destination.path)", "-p\(password ?? "")"]
        // -bb1 makes 7zz log one line per extracted entry so we can report progress.
        if onEntryExtracted != nil { args.append("-bb1") }
        args.append(archive.path)
        if let entries {
            args.append(contentsOf: entries)
        }
        let result: RunResult
        if let onEntryExtracted {
            result = try runStreaming(args) { line in
                if SevenZipRunner.isEntryLine(line) { onEntryExtracted() }
            }
        } else {
            result = try run(args)
        }
        guard result.code == 0 else {
            let combined = result.stdout + result.stderr
            if combined.contains("Wrong password") || combined.contains("Headers Error") {
                throw ArchiveError.wrongPassword
            }
            throw ArchiveError.executionFailed(
                code: result.code,
                message: combined.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
```

然后把 5 参 `extract`(现第 102–115 行,带 `singleTopLevelDir`)替换为(签名加 `onEntryExtracted`,两处内部调用透传):

```swift
    public func extract(archive: URL, entries: [String]?, singleTopLevelDir: String?,
                        to finalFolder: URL, password: String?,
                        onEntryExtracted: (@Sendable () -> Void)? = nil) throws {
        let fm = FileManager.default
        guard let topDir = singleTopLevelDir else {
            try extract(archive: archive, entries: entries, to: finalFolder, password: password,
                        onEntryExtracted: onEntryExtracted)
            return
        }
        let parent = finalFolder.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".7zip-swiftui-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try extract(archive: archive, entries: entries, to: temp, password: password,
                    onEntryExtracted: onEntryExtracted)
        try fm.moveItem(at: temp.appendingPathComponent(topDir), to: finalFolder)
    }
```

(其上方的文档注释块保持不变。)

- [ ] **Step 5: 跑测试确认通过**

Run: `make test`
Expected: PASS —— `isEntryLine` 单测与 `-bb1` 进度集成测试全绿,原有解压测试不回归。

- [ ] **Step 6: 提交**

```bash
git add Sources/ArchiveKit/SevenZipRunner.swift Tests/ArchiveKitTests/SevenZipRunnerTests.swift
git commit -m "feat(progress): stream 7zz -bb1 per-entry output via extract onEntryExtracted callback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 端到端接线 — Controller 进度 + 遮罩 overlay

**Files:**
- Modify: `Sources/SevenZipApp/ExtractionController.swift`
- Create: `Sources/SevenZipApp/ExtractionProgressOverlay.swift`
- Modify: `Sources/SevenZipApp/App.swift`(`ArchiveWindow`:`progress` 状态、overlay、`runExtraction`)

**Interfaces:**
- Consumes: `ExtractionProgress.totalEntryCount(entries:selectedPaths:)`(Task 1);`SevenZipRunner.extract(archive:entries:singleTopLevelDir:to:password:onEntryExtracted:)`(Task 2);现有 `ExtractionTarget.hasSingleTopLevelDirectory`、`ExtractionTarget.archiveBaseName`、`ExtractionTarget.resolve`。
- Produces:
  - `ExtractionController.extract(...)` 增加末参 `onProgress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void`。
  - `enum ExtractionProgressState: Equatable { case indeterminate; case determinate(fraction: Double) }`。
  - `struct ExtractionProgressOverlay: View`(`let state: ExtractionProgressState`)。

- [ ] **Step 1: `ExtractionController` 加 `onProgress` + 线程安全计数**

在 `Sources/SevenZipApp/ExtractionController.swift` 顶部(`import` 之后、`enum CollisionChoice` 之前)加一个计数器:

```swift
/// Thread-safe counter for entries extracted so far. `extract` runs the 7z work on a
/// detached thread; the callback fires there, so increments must be locked.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
```

把 `extract(...)` 方法整体替换为(签名加 `onProgress`;解压前算 `total` 并先报一次 `(0, total)` 建立 indeterminate;每条目 marshal 回主线程):

```swift
    func extract(
        archive: URL,
        entries: [ArchiveEntry],
        selectedPaths: [String]?,
        password: String?,
        resolveCollision: (URL) async -> CollisionChoice,
        onProgress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let parent = archive.deletingLastPathComponent()
        let baseName = ExtractionTarget.hasSingleTopLevelDirectory(entries)
            ?? ExtractionTarget.archiveBaseName(archive)
        let firstChoice = parent.appendingPathComponent(baseName)

        var destination = firstChoice
        if fm.fileExists(atPath: firstChoice.path) {
            switch await resolveCollision(firstChoice) {
            case .cancel:
                throw CancellationError()
            case .deleteExisting:
                try fm.removeItem(at: firstChoice)
                destination = firstChoice
            case .numbered:
                destination = ExtractionTarget.resolve(
                    archive: archive, entries: entries,
                    directoryExists: { fm.fileExists(atPath: $0.path) }
                )
            }
        }

        let total = ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: selectedPaths)
        // Establish the overlay now that collisions are resolved and extraction is starting.
        onProgress(0, total)

        let runner = self.runner
        let dest = destination
        let singleTopDir = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        let counter = ProgressCounter()
        try await Task.detached {
            try runner.extract(archive: archive, entries: selectedPaths,
                               singleTopLevelDir: singleTopDir, to: dest, password: password,
                               onEntryExtracted: {
                let done = counter.increment()
                Task { @MainActor in onProgress(done, total) }
            })
        }.value
        return destination
    }
```

- [ ] **Step 2: 新建遮罩组件**

创建 `Sources/SevenZipApp/ExtractionProgressOverlay.swift`:

```swift
import SwiftUI

/// Progress of an in-flight extraction. Starts `.indeterminate` (before any entry line
/// arrives, or when the archive never emits per-entry lines) and becomes `.determinate`
/// once real per-entry counts come in.
enum ExtractionProgressState: Equatable {
    case indeterminate
    case determinate(fraction: Double)
}

/// Dimmed, centered card shown over the archive window while an extraction runs.
/// Non-dismissable; there is no cancel affordance by design.
struct ExtractionProgressOverlay: View {
    let state: ExtractionProgressState

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                switch state {
                case .indeterminate:
                    ProgressView().controlSize(.large)
                    Text("正在解压…")
                case .determinate(let fraction):
                    ProgressView(value: fraction).frame(width: 220)
                    Text("正在解压… \(Int(fraction * 100))%")
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
        }
    }
}

struct ExtractionProgressOverlay_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ExtractionProgressOverlay(state: .indeterminate)
            ExtractionProgressOverlay(state: .determinate(fraction: 0.45))
        }
    }
}
```

- [ ] **Step 3: `ArchiveWindow` 加进度状态与 overlay**

在 `Sources/SevenZipApp/App.swift` 的 `ArchiveWindow` 中,`@State private var passwordContext: PasswordContext = .unlock` 附近新增:

```swift
    @State private var progress: ExtractionProgressState?
```

在 `body` 中,给 `content` 链上追加一个 overlay(放在现有底部 toast overlay 之后即可):

```swift
            .overlay {
                if let progress {
                    ExtractionProgressOverlay(state: progress)
                }
            }
```

- [ ] **Step 4: `runExtraction` 接线进度**

把 `Sources/SevenZipApp/App.swift` 中现有的 `runExtraction(selectedPaths:)` 整体替换为(新增 `onProgress:` 实参、`defer` 里清 `progress`;成功/错误处理保持不变):

```swift
    private func runExtraction(selectedPaths: [String]?) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false; progress = nil }
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
                    },
                    onProgress: { completed, total in
                        progress = (completed > 0 && total > 0)
                            ? .determinate(fraction: min(1, Double(completed) / Double(total)))
                            : .indeterminate
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

- [ ] **Step 5: 重生成工程并构建**

新增了 `ExtractionProgressOverlay.swift`,需先重生成 `.xcodeproj`:

Run: `xcodegen generate && make build`
Expected: BUILD SUCCEEDED,无错误、无 Swift 6 并发告警。

- [ ] **Step 6: 手动验证(GUI)**

Run: `make run`

手动确认:
1. 解压一个**多文件**压缩包 → 解压期间中央出现遮罩卡片,进度条随文件推进增长,文案「正在解压… N%」,完成即消失、并照常给出成功反馈(打开 Finder / toast / 无)。
2. 目标夹已存在触发碰撞对话框时 → 遮罩在**回答碰撞对话框之后**才出现(不会遮住碰撞/密码弹窗)。
3. 碰撞对话框点「取消」→ 无遮罩残留、静默。
4. (若手边有)解压一个 7zz 不吐逐条目行的压缩包 → 全程 indeterminate 转圈,不卡死、完成消失。

- [ ] **Step 7: 提交**

```bash
git add Sources/SevenZipApp/ExtractionController.swift Sources/SevenZipApp/ExtractionProgressOverlay.swift Sources/SevenZipApp/App.swift
git commit -m "feat(progress): show extraction progress overlay (real per-entry %, indeterminate fallback)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- ① Runner 流式 + `extract` 回调 + `-bb1` + `isEntryLine` 纯函数 → Task 2。✅
- ② `ExtractionProgress.totalEntryCount`(全部/选中子树/前缀不误伤兄弟)+ 单测 → Task 1。✅
- ③ `ExtractionController` `onProgress` + 算 total + 线程安全计数 + marshal 回主线程 → Task 3 Step 1。✅
- ④ `ExtractionProgressState`(indeterminate/determinate)、`runExtraction` 驱动、中央半透明遮罩卡片、无取消 → Task 3 Steps 2–4。✅
- 「先真退化到假」自动判定:Task 3 —— `onProgress(0,total)` 建立 indeterminate;`completed>0 && total>0` 才转 determinate;不吐条目行则恒 indeterminate。✅
- 真实 `-bb1` 集成测试(回调计数) → Task 2 Step 1。✅
- 遮罩在碰撞/密码弹窗**之后**才出现:Task 3 —— `onProgress(0,total)` 在碰撞解决之后调用,UI 不在 `runExtraction` 开头预置 indeterminate。✅

**Type consistency:**
- `onEntryExtracted: (@Sendable () -> Void)?` 在 Task 2 两个重载定义,Task 3 controller 透传实参一致。
- `onProgress: @escaping @MainActor (Int, Int) -> Void` 在 Task 3 controller 定义,App.swift 实参签名 `{ completed, total in }` 一致。
- `ExtractionProgressState` cases `indeterminate` / `determinate(fraction:)` 在 overlay 定义,`runExtraction` 与 overlay `switch` 用法一致。
- `ExtractionProgress.totalEntryCount(entries:selectedPaths:)` 在 Task 1 定义,Task 3 调用签名一致。
- `SevenZipRunner.isEntryLine(_:)` 在 Task 2 定义并在其内部 `runStreaming` 回调 + 单测中调用一致。

**Placeholder scan:** 无 TODO/TBD;每个改代码步骤均给完整代码块与预期输出。Task 3 合并 controller+UI 为一个「端到端接线」交付物,因 controller 签名改动会强制 App.swift 同步、二者同一 build 才绿,故不拆分。

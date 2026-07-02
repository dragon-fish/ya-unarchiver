# 解压选项对话框 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增仿 Windows 7-Zip「解压」对话框(解压位置/子文件夹/排除重复根目录/覆盖模式/密码),与现有一键极速解压汇入同一控制层。

**Architecture:** 纯值类型 `ExtractOptions`(ArchiveKit)承载对话框输出,含可单测的 `validate`/`resolveDestination`/`defaults`;`ExtractionController.extract` 统一消费它,一键路用默认选项、对话框路用用户编辑选项;SwiftUI `ExtractOptionsView` 只做输入与实时反馈,不含解压逻辑。

**Tech Stack:** Swift 6, SwiftUI, XCTest, XcodeGen + xcodebuild(`make build`/`make test`),SPM(`swift test` 跑纯 ArchiveKit 逻辑)。

## Global Constraints

- 部署目标 macOS 14.0,`SWIFT_VERSION 6.0`。
- 新增源文件放 `Sources/ArchiveKit/` 或 `Sources/SevenZipApp/`,由 XcodeGen 目录 glob 自动纳入,**不改 `project.yml`**。
- 面向用户文案沿用现有**简体中文硬编码**风格,不引入本地化。
- **永不篡改/拦截用户输入**:合法性只通过 UI 反馈(红框、内联红字、按钮禁用)体现。
- 覆盖粒度=文件夹级,复用 App 层 `CollisionChoice`;不引入 7zz 文件级 `-ao*`。
- 纯逻辑用 `swift test` TDD;UI 接线用 `make build` + 手动验证。
- Commit message 用英文 Conventional Commits;每个 Task 末尾 commit 一次。

---

### Task 1: `ExtractOptions` 值类型 + 校验(纯逻辑)

**Files:**
- Create: `Sources/ArchiveKit/ExtractOptions.swift`
- Modify: `Sources/ArchiveKit/ArchiveError.swift`
- Test: `Tests/ArchiveKitTests/ExtractOptionsTests.swift`

**Interfaces:**
- Produces:
  - `enum OverwritePolicy: String, Sendable, CaseIterable { case ask, numbered, deleteExisting }`
  - `enum ExtractValidationError: Equatable, Sendable { case locationEmpty, locationNotADirectory, locationNotWritable, invalidSubfolderName }`
  - `struct ExtractOptions: Sendable`(字段见下)+ `init`
  - `func validate(fileManager: FileManager = .default) -> [ExtractValidationError]`
  - `static func normalizeLocation(_ text: String) -> URL`
  - `ArchiveError.invalidDestination(String)`

- [ ] **Step 1: 写失败测试**

`Tests/ArchiveKitTests/ExtractOptionsTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class ExtractOptionsTests: XCTestCase {

    /// A real, writable temp directory to use as a valid `location`.
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("extractopts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func options(location: URL, subEnabled: Bool = true, subName: String = "out",
                         strip: Bool = true, overwrite: OverwritePolicy = .ask,
                         password: String = "") -> ExtractOptions {
        ExtractOptions(location: location, subfolderEnabled: subEnabled, subfolderName: subName,
                       stripSingleTopDir: strip, overwriteMode: overwrite, password: password)
    }

    func test_validate_passes_for_writable_dir_and_clean_name() throws {
        let dir = try tempDir()
        XCTAssertEqual(options(location: dir).validate(), [])
    }

    func test_validate_flags_nonexistent_location() {
        let missing = URL(fileURLWithPath: "/no/such/dir-\(UUID().uuidString)")
        XCTAssertEqual(options(location: missing).validate(), [.locationNotADirectory])
    }

    func test_validate_flags_file_location_as_not_a_directory() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(options(location: file).validate(), [.locationNotADirectory])
    }

    func test_validate_rejects_subfolder_names_with_illegal_chars() throws {
        let dir = try tempDir()
        for bad in ["a/b", "a:b", ".", "..", "../x"] {
            XCTAssertEqual(options(location: dir, subName: bad).validate(), [.invalidSubfolderName],
                           "expected \(bad) to be invalid")
        }
    }

    func test_validate_trims_whitespace_then_accepts() throws {
        let dir = try tempDir()
        XCTAssertEqual(options(location: dir, subName: "  keep  ").validate(), [])
    }

    func test_validate_empty_subfolder_name_is_not_an_error() throws {
        let dir = try tempDir()
        // Empty name = "no subfolder / dump" — a warning case, not a validation error.
        XCTAssertEqual(options(location: dir, subName: "   ").validate(), [])
    }

    func test_normalizeLocation_expands_tilde_and_standardizes() {
        let url = ExtractOptions.normalizeLocation("~/Downloads/../Downloads")
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertFalse(url.path.contains(".."))
        XCTAssertTrue(url.path.hasSuffix("/Downloads"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ExtractOptionsTests`
Expected: FAIL(`ExtractOptions` / `OverwritePolicy` 未定义)

- [ ] **Step 3: 加 `ArchiveError.invalidDestination`**

`Sources/ArchiveKit/ArchiveError.swift`,在枚举里追加一个 case:

```swift
public enum ArchiveError: Error, Equatable {
    case needsPassword
    case wrongPassword
    case corrupted(String)
    case binaryNotFound
    case executionFailed(code: Int32, message: String)
    case invalidDestination(String)
}
```

- [ ] **Step 4: 写 `ExtractOptions.swift`**

`Sources/ArchiveKit/ExtractOptions.swift`:

```swift
import Foundation

/// 目标文件夹已存在时的处理策略(文件夹级)。
public enum OverwritePolicy: String, Sendable, CaseIterable {
    case ask            // 反应式弹碰撞框
    case numbered       // 解压到带序号的新文件夹
    case deleteExisting // 删除原文件夹再解压
}

/// 校验失败原因。UI 据此渲染红框/红字并禁用「解压」。
public enum ExtractValidationError: Equatable, Sendable {
    case locationEmpty
    case locationNotADirectory
    case locationNotWritable
    case invalidSubfolderName
}

/// 「解压到…」对话框的输出;也用于一键路(由 `defaults` 构造)。
public struct ExtractOptions: Sendable {
    public var location: URL            // 容器目录(已归一)
    public var subfolderEnabled: Bool
    public var subfolderName: String    // 勾选时的子文件夹名
    public var stripSingleTopDir: Bool  // 排除重复根目录
    public var overwriteMode: OverwritePolicy
    public var password: String

    public init(location: URL, subfolderEnabled: Bool, subfolderName: String,
                stripSingleTopDir: Bool, overwriteMode: OverwritePolicy, password: String) {
        self.location = location
        self.subfolderEnabled = subfolderEnabled
        self.subfolderName = subfolderName
        self.stripSingleTopDir = stripSingleTopDir
        self.overwriteMode = overwriteMode
        self.password = password
    }

    /// 把用户输入的位置文本归一为绝对 URL(展开 ~、消除 ../.）。
    public static func normalizeLocation(_ text: String) -> URL {
        let expanded = (text as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// 纯校验。空的子文件夹名不算错误(= 不建子文件夹的 dump 情形)。
    public func validate(fileManager fm: FileManager = .default) -> [ExtractValidationError] {
        var errors: [ExtractValidationError] = []

        let path = location.path
        if path.isEmpty {
            errors.append(.locationEmpty)
        } else {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                errors.append(.locationNotADirectory)
            } else if !fm.isWritableFile(atPath: path) {
                errors.append(.locationNotWritable)
            }
        }

        if subfolderEnabled {
            let name = subfolderName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                if name == "." || name == ".." || name.contains("/") || name.contains(":") {
                    errors.append(.invalidSubfolderName)
                }
            }
        }
        return errors
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter ExtractOptionsTests`
Expected: PASS(7 个用例)

- [ ] **Step 6: Commit**

```bash
git add Sources/ArchiveKit/ExtractOptions.swift Sources/ArchiveKit/ArchiveError.swift Tests/ArchiveKitTests/ExtractOptionsTests.swift
git commit -m "feat(archivekit): ExtractOptions value type with pure validation"
```

---

### Task 2: 目标解析 + 默认选项 + 带序号助手(纯逻辑)

**Files:**
- Modify: `Sources/ArchiveKit/ExtractOptions.swift`
- Modify: `Sources/ArchiveKit/ExtractionTarget.swift`
- Test: `Tests/ArchiveKitTests/ExtractOptionsTests.swift`(追加)

**Interfaces:**
- Consumes(Task 1):`ExtractOptions`、`OverwritePolicy`、`ArchiveError.invalidDestination`。
- Consumes(既有):`ExtractionTarget.hasSingleTopLevelDirectory([ArchiveEntry]) -> String?`、`ExtractionTarget.archiveBaseName(URL) -> String`、`ArchiveEntry`。
- Produces:
  - `struct ResolvedDestination: Sendable, Equatable { let finalFolder: URL; let dumpIntoExisting: Bool; let stripTopDir: String? }`
  - `func resolveDestination(singleTopLevelDir: String?, fileManager: FileManager = .default) throws -> ResolvedDestination`
  - `static func defaults(archive: URL, entries: [ArchiveEntry], password: String) -> ExtractOptions`
  - `static func ExtractionTarget.numbered(base: URL, directoryExists: (URL) -> Bool) -> URL`

- [ ] **Step 1: 写失败测试(追加到 ExtractOptionsTests)**

在 `ExtractOptionsTests` 类内追加:

```swift
    private func entry(_ path: String, dir: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil,
                     isDirectory: dir, isEncrypted: false)
    }

    func test_resolve_subfolder_enabled_appends_name_and_strips() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "proj", strip: true)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertEqual(r.finalFolder, dir.appendingPathComponent("proj"))
        XCTAssertFalse(r.dumpIntoExisting)
        XCTAssertEqual(r.stripTopDir, "proj")
    }

    func test_resolve_strip_off_keeps_topdir() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "proj", strip: false)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertNil(r.stripTopDir)
    }

    func test_resolve_no_singletopdir_yields_nil_strip() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "proj", strip: true)
            .resolveDestination(singleTopLevelDir: nil)
        XCTAssertNil(r.stripTopDir)
    }

    func test_resolve_dump_when_subfolder_disabled() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subEnabled: false, subName: "proj", strip: true)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertEqual(r.finalFolder, dir)
        XCTAssertTrue(r.dumpIntoExisting)
        XCTAssertNil(r.stripTopDir)
    }

    func test_resolve_dump_when_subfolder_name_empty() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "   ", strip: true)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertEqual(r.finalFolder, dir)
        XCTAssertTrue(r.dumpIntoExisting)
    }

    func test_resolve_throws_on_invalid() throws {
        let missing = URL(fileURLWithPath: "/no/such/dir-\(UUID().uuidString)")
        XCTAssertThrowsError(try options(location: missing)
            .resolveDestination(singleTopLevelDir: nil)) { error in
            guard case ArchiveError.invalidDestination = error else {
                return XCTFail("expected invalidDestination, got \(error)")
            }
        }
    }

    func test_defaults_match_legacy_target_single_topdir() throws {
        let parent = try tempDir()
        let archive = parent.appendingPathComponent("foo.7z")
        let entries = [entry("proj", dir: true), entry("proj/a.txt", dir: false)]
        let opts = ExtractOptions.defaults(archive: archive, entries: entries, password: "")
        let top = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        let r = try opts.resolveDestination(singleTopLevelDir: top)
        // Legacy: firstChoice = parent/(topdir ?? baseName) = parent/proj ; strip = topdir
        XCTAssertEqual(r.finalFolder, parent.appendingPathComponent("proj"))
        XCTAssertEqual(r.stripTopDir, "proj")
    }

    func test_defaults_match_legacy_target_no_topdir() throws {
        let parent = try tempDir()
        let archive = parent.appendingPathComponent("foo.7z")
        let entries = [entry("a.txt", dir: false), entry("b.txt", dir: false)]
        let opts = ExtractOptions.defaults(archive: archive, entries: entries, password: "")
        let r = try opts.resolveDestination(singleTopLevelDir: nil)
        XCTAssertEqual(r.finalFolder, parent.appendingPathComponent("foo"))
        XCTAssertNil(r.stripTopDir)
    }

    func test_numbered_appends_suffix_until_free() {
        var existing: Set<String> = ["/d/proj", "/d/proj 2"]
        let out = ExtractionTarget.numbered(base: URL(fileURLWithPath: "/d/proj"),
                                            directoryExists: { existing.contains($0.path) })
        XCTAssertEqual(out, URL(fileURLWithPath: "/d/proj 3"))
        _ = existing // silence unused-mutability
    }

    func test_numbered_returns_base_when_free() {
        let out = ExtractionTarget.numbered(base: URL(fileURLWithPath: "/d/proj"),
                                            directoryExists: { _ in false })
        XCTAssertEqual(out, URL(fileURLWithPath: "/d/proj"))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ExtractOptionsTests`
Expected: FAIL(`resolveDestination` / `defaults` / `ExtractionTarget.numbered` 未定义)

- [ ] **Step 3: 加 `numbered` 到 ExtractionTarget**

`Sources/ArchiveKit/ExtractionTarget.swift`,在 `enum ExtractionTarget` 内追加:

```swift
    /// Appends " 2", " 3", … to `base`'s last path component until it doesn't exist.
    public static func numbered(base: URL, directoryExists: (URL) -> Bool) -> URL {
        guard directoryExists(base) else { return base }
        let parent = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        var counter = 2
        var candidate = parent.appendingPathComponent("\(name) \(counter)")
        while directoryExists(candidate) {
            counter += 1
            candidate = parent.appendingPathComponent("\(name) \(counter)")
        }
        return candidate
    }
```

- [ ] **Step 4: 加 `ResolvedDestination` / `resolveDestination` / `defaults` 到 ExtractOptions.swift**

在 `Sources/ArchiveKit/ExtractOptions.swift` 文件末尾追加:

```swift
/// `resolveDestination` 的结果。
public struct ResolvedDestination: Sendable, Equatable {
    public let finalFolder: URL
    public let dumpIntoExisting: Bool   // true = 直接铺进已存在容器(跳过文件夹级碰撞)
    public let stripTopDir: String?     // 传给 runner 的 singleTopLevelDir
}

extension ExtractOptions {
    /// 由选项 + 压缩包单顶层目录算出最终落点。非法则 fail-fast 抛 invalidDestination。
    public func resolveDestination(singleTopLevelDir: String?,
                                   fileManager fm: FileManager = .default) throws -> ResolvedDestination {
        guard validate(fileManager: fm).isEmpty else {
            throw ArchiveError.invalidDestination("解压位置或文件夹名无效")
        }
        let name = subfolderName.trimmingCharacters(in: .whitespaces)
        if subfolderEnabled && !name.isEmpty {
            return ResolvedDestination(
                finalFolder: location.appendingPathComponent(name),
                dumpIntoExisting: false,
                stripTopDir: stripSingleTopDir ? singleTopLevelDir : nil
            )
        }
        // 不建子文件夹:铺进容器,strip 不适用。
        return ResolvedDestination(finalFolder: location, dumpIntoExisting: true, stripTopDir: nil)
    }

    /// 一键路默认选项。子文件夹名取「单顶层目录名 ?? 包名」以保持与旧一键行为逐字节一致。
    public static func defaults(archive: URL, entries: [ArchiveEntry], password: String) -> ExtractOptions {
        let baseName = ExtractionTarget.hasSingleTopLevelDirectory(entries)
            ?? ExtractionTarget.archiveBaseName(archive)
        return ExtractOptions(
            location: archive.deletingLastPathComponent(),
            subfolderEnabled: true,
            subfolderName: baseName,
            stripSingleTopDir: true,
            overwriteMode: .ask,
            password: password
        )
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter ExtractOptionsTests`
Expected: PASS(全部,含 Task 1 的 7 + 本任务 10)

- [ ] **Step 6: Commit**

```bash
git add Sources/ArchiveKit/ExtractOptions.swift Sources/ArchiveKit/ExtractionTarget.swift Tests/ArchiveKitTests/ExtractOptionsTests.swift
git commit -m "feat(archivekit): destination resolution, defaults, numbered helper"
```

---

### Task 3: `ExtractionController` 统一消费 `ExtractOptions`

**Files:**
- Modify: `Sources/SevenZipApp/ExtractionController.swift`
- Modify: `Sources/SevenZipApp/App.swift:284-334`(`runExtraction` 及调用点)

**Interfaces:**
- Consumes:`ExtractOptions`、`ResolvedDestination`、`OverwritePolicy`、`ExtractionTarget.numbered`、`ExtractOptions.defaults`。
- Produces(供 Task 5):`ExtractionController.extract(archive:entries:selectedPaths:options:resolveCollision:onProgress:) async throws -> URL`;`ArchiveWindow.runExtraction(selectedPaths:options:)`(`options` 默认 `nil` = 一键路)。

- [ ] **Step 1: 重写 `ExtractionController.extract` 签名与体**

替换 `Sources/SevenZipApp/ExtractionController.swift` 中的 `func extract(...)`(第 21-68 行)整段为:

```swift
    /// 用 `options` 解析目标、处理文件夹级碰撞,然后解压。返回最终目标目录。
    func extract(
        archive: URL,
        entries: [ArchiveEntry],
        selectedPaths: [String]?,
        options: ExtractOptions,
        resolveCollision: (URL) async -> CollisionChoice,
        onProgress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let singleTopDir = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        let resolved = try options.resolveDestination(singleTopLevelDir: singleTopDir)

        var destination = resolved.finalFolder
        if !resolved.dumpIntoExisting && fm.fileExists(atPath: destination.path) {
            switch options.overwriteMode {
            case .ask:
                switch await resolveCollision(destination) {
                case .cancel:
                    throw CancellationError()
                case .deleteExisting:
                    try fm.removeItem(at: destination)
                case .numbered:
                    destination = ExtractionTarget.numbered(
                        base: resolved.finalFolder,
                        directoryExists: { fm.fileExists(atPath: $0.path) })
                }
            case .numbered:
                destination = ExtractionTarget.numbered(
                    base: resolved.finalFolder,
                    directoryExists: { fm.fileExists(atPath: $0.path) })
            case .deleteExisting:
                try fm.removeItem(at: destination)
            }
        }

        let total = ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: selectedPaths)
        onProgress(0, total)

        let runner = self.runner
        let dest = destination
        let strip = resolved.stripTopDir
        let password = options.password
        let counter = ProgressCounter()
        try await Task.detached {
            try runner.extract(archive: archive, entries: selectedPaths,
                               singleTopLevelDir: strip, to: dest, password: password,
                               onEntryExtracted: {
                let done = counter.increment()
                Task { @MainActor in onProgress(done, total) }
            })
        }.value
        return destination
    }
```

(`CollisionChoice` 枚举与 `ProgressCounter` 保持在本文件顶部不变。)

- [ ] **Step 2: 改 `App.swift` 的 `runExtraction` 支持 options**

`Sources/SevenZipApp/App.swift`,把 `runExtraction(selectedPaths:)` 的签名与首段(第 284-306 行区域)改为:

```swift
    private func runExtraction(selectedPaths: [String]?, options: ExtractOptions? = nil) {
        guard !isExtracting else { return }
        isExtracting = true
        Task {
            defer { isExtracting = false; progress = nil }
            let opts = options ?? ExtractOptions.defaults(
                archive: archiveURL,
                entries: model.lastEntries,
                password: extractPassword ?? model.password ?? "")
            do {
                let dest = try await controller.extract(
                    archive: archiveURL,
                    entries: model.lastEntries,
                    selectedPaths: selectedPaths,
                    options: opts,
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
```

其余 `switch postExtractAction { … }` 与各 `catch` 分支保持不变。

- [ ] **Step 3: 构建验证**

Run: `make build`
Expected: BUILD SUCCEEDED(编译通过,一键路已切到新签名)

- [ ] **Step 4: 跑纯测试确认无回归**

Run: `swift test --filter ExtractOptionsTests && swift test --filter ExtractionTargetTests`
Expected: PASS

- [ ] **Step 5: 手动冒烟(一键路不变)**

Run: `make run`
手动:打开一个压缩包,点「解压全部」→ 应与之前一致(解压到旁边、碰撞时弹框);点「解压选中」某项 → 正常。关闭。

- [ ] **Step 6: Commit**

```bash
git add Sources/SevenZipApp/ExtractionController.swift Sources/SevenZipApp/App.swift
git commit -m "refactor(extract): funnel one-click extraction through ExtractOptions"
```

---

### Task 4: `ExtractOptionsView` 对话框视图

**Files:**
- Create: `Sources/SevenZipApp/ExtractOptionsView.swift`

**Interfaces:**
- Consumes:`ExtractOptions`、`OverwritePolicy`、`ExtractValidationError`、`ResolvedDestination`、`ExtractOptions.normalizeLocation`、`resolveDestination`、`validate`。
- Produces(供 Task 5):
  - `struct ExtractOptionsView: View`,init 参数:
    `defaults: ExtractOptions, singleTopLevelDir: String?, isEncrypted: Bool, errorMessage: String?, onExtract: (ExtractOptions) -> Void, onCancel: () -> Void`

- [ ] **Step 1: 写视图**

`Sources/SevenZipApp/ExtractOptionsView.swift`:

```swift
import SwiftUI
import AppKit
import ArchiveKit

/// 仿 Windows 7-Zip「解压」对话框。只做输入与实时反馈,不含解压逻辑;
/// 确认后把编辑好的 `ExtractOptions` 交回调用方。
struct ExtractOptionsView: View {
    let defaults: ExtractOptions
    let singleTopLevelDir: String?
    let isEncrypted: Bool
    let errorMessage: String?
    let onExtract: (ExtractOptions) -> Void
    let onCancel: () -> Void

    @State private var locationText: String
    @State private var subfolderEnabled: Bool
    @State private var subfolderName: String
    @State private var stripSingleTopDir: Bool
    @State private var overwriteMode: OverwritePolicy
    @State private var password: String
    @State private var showPassword = false

    init(defaults: ExtractOptions, singleTopLevelDir: String?, isEncrypted: Bool,
         errorMessage: String?, onExtract: @escaping (ExtractOptions) -> Void,
         onCancel: @escaping () -> Void) {
        self.defaults = defaults
        self.singleTopLevelDir = singleTopLevelDir
        self.isEncrypted = isEncrypted
        self.errorMessage = errorMessage
        self.onExtract = onExtract
        self.onCancel = onCancel
        _locationText = State(initialValue: defaults.location.path)
        _subfolderEnabled = State(initialValue: defaults.subfolderEnabled)
        _subfolderName = State(initialValue: defaults.subfolderName)
        _stripSingleTopDir = State(initialValue: defaults.stripSingleTopDir)
        _overwriteMode = State(initialValue: defaults.overwriteMode)
        _password = State(initialValue: defaults.password)
    }

    // MARK: Derived

    private var currentOptions: ExtractOptions {
        ExtractOptions(location: ExtractOptions.normalizeLocation(locationText),
                       subfolderEnabled: subfolderEnabled, subfolderName: subfolderName,
                       stripSingleTopDir: stripSingleTopDir, overwriteMode: overwriteMode,
                       password: password)
    }

    private var errors: [ExtractValidationError] { currentOptions.validate() }
    private var locationInvalid: Bool {
        errors.contains(.locationEmpty) || errors.contains(.locationNotADirectory)
            || errors.contains(.locationNotWritable)
    }
    private var subfolderInvalid: Bool { errors.contains(.invalidSubfolderName) }

    private var previewPath: String {
        (try? currentOptions.resolveDestination(singleTopLevelDir: singleTopLevelDir))?
            .finalFolder.path ?? "—"
    }
    private var willDump: Bool {
        subfolderEnabled && subfolderName.trimmingCharacters(in: .whitespaces).isEmpty
            || !subfolderEnabled
    }
    private var locationChanged: Bool { locationText != defaults.location.path }
    private var subfolderChanged: Bool { subfolderName != defaults.subfolderName }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解压").font(.headline)

            locationRow
            subfolderRow

            Toggle("排除重复的根文件夹", isOn: $stripSingleTopDir)

            Picker("已存在时", selection: $overwriteMode) {
                Text("询问").tag(OverwritePolicy.ask)
                Text("解压到带序号文件夹").tag(OverwritePolicy.numbered)
                Text("删除原文件夹").tag(OverwritePolicy.deleteExisting)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            passwordRow

            previewAndWarnings

            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("解压") { onExtract(currentOptions) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!errors.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: Rows

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("解压位置").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $locationText)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(locationInvalid ? Color.red : Color.clear, lineWidth: 1))
                if locationChanged {
                    Button { locationText = defaults.location.path } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("还原默认")
                }
                Button("…") { browseForLocation() }
            }
        }
    }

    private var subfolderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("到文件夹", isOn: $subfolderEnabled)
                    .toggleStyle(.checkbox)
                TextField("", text: $subfolderName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!subfolderEnabled)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(subfolderInvalid ? Color.red : Color.clear, lineWidth: 1))
                if subfolderChanged {
                    Button { subfolderName = defaults.subfolderName } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("还原默认")
                }
            }
        }
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("密码").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if showPassword {
                        TextField("", text: $password)
                    } else {
                        SecureField("", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Toggle("显示密码", isOn: $showPassword).toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var previewAndWarnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将解压到:\(previewPath)")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon")
                    .font(.caption).foregroundStyle(.red)
            }
            if subfolderInvalid {
                Label("文件夹名不能包含 / 或 :,也不能是 . 或 ..", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if locationInvalid {
                Label("解压位置必须是已存在且可写的目录", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if willDump && !locationInvalid {
                Label("文件将直接解压到该位置,可能覆盖同名文件", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Actions

    private func browseForLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ExtractOptions.normalizeLocation(locationText)
        if panel.runModal() == .OK, let url = panel.url {
            locationText = url.path
        }
    }
}
```

- [ ] **Step 2: 构建验证**

Run: `make build`
Expected: BUILD SUCCEEDED(视图编译通过;此时尚未接线,不会显示)

- [ ] **Step 3: Commit**

```bash
git add Sources/SevenZipApp/ExtractOptionsView.swift
git commit -m "feat(ui): extract options dialog view with live validation and preview"
```

---

### Task 5: 入口接线(分体菜单 + sheet + 密码错误重弹)

**Files:**
- Modify: `Sources/SevenZipApp/App.swift`(工具栏、sheet、对话框路)
- Modify: `Sources/SevenZipApp/TwoPaneBrowserView.swift:179`(右键接对话框路)

**Interfaces:**
- Consumes:`ExtractOptionsView`、`ExtractOptions`、`ExtractOptions.defaults`、`ArchiveWindow.runExtraction(selectedPaths:options:)`。

- [ ] **Step 1: 在 `ArchiveWindow` 加对话框状态**

`Sources/SevenZipApp/App.swift`,在 `@State private var progress …` 附近(第 166 行后)追加:

```swift
    @State private var showExtractDialog = false
    @State private var extractDialogPaths: [String]? = nil   // nil = 全部
    @State private var extractDialogError: String? = nil
```

- [ ] **Step 2: 工具栏两个按钮改为分体菜单**

替换 `.toolbar { ToolbarItemGroup { … } }`(第 196-207 行)为:

```swift
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("解压到…") { presentExtractDialog(paths: nil) }
                    } label: {
                        Label("解压全部", systemImage: "arrow.down.doc")
                    } primaryAction: {
                        extractAll()
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(isExtracting)
                    .help("解压整个压缩包(点右侧箭头可设选项)")

                    Menu {
                        Button("解压选中到…") { presentExtractDialog(paths: Array(selection)) }
                    } label: {
                        Label("解压选中", systemImage: "arrow.down.square")
                    } primaryAction: {
                        extractSelected(selection)
                    }
                    .disabled(selection.isEmpty || isExtracting)
                    .help("解压当前选中的项目(点右侧箭头可设选项)")
                }
            }
```

- [ ] **Step 3: 加 sheet 与 present 逻辑**

在 `.alert("解压失败", …)`(第 248-252 行)之后追加一个 `.sheet`:

```swift
            .sheet(isPresented: $showExtractDialog) {
                ExtractOptionsView(
                    defaults: ExtractOptions.defaults(
                        archive: archiveURL,
                        entries: extractDialogEntries,
                        password: extractPassword ?? model.password ?? ""),
                    singleTopLevelDir: ExtractionTarget.hasSingleTopLevelDirectory(extractDialogEntries),
                    isEncrypted: model.password != nil,
                    errorMessage: extractDialogError,
                    onExtract: { opts in
                        showExtractDialog = false
                        extractDialogError = nil
                        runExtraction(selectedPaths: extractDialogPaths, options: opts)
                    },
                    onCancel: {
                        showExtractDialog = false
                        extractDialogError = nil
                    }
                )
            }
```

并在 `extractSelected(_:)` 附近(第 278-282 行后)加辅助方法:

```swift
    /// 对话框看到的 entries 始终是全量条目(用于单顶层目录检测与默认名);
    /// 具体解压范围由 extractDialogPaths 决定。
    private var extractDialogEntries: [ArchiveEntry] { model.lastEntries }

    private func presentExtractDialog(paths: [String]?) {
        guard !isExtracting else { return }
        extractDialogPaths = paths
        extractDialogError = nil
        showExtractDialog = true
    }
```

- [ ] **Step 4: 对话框路的密码错误重弹**

在 `runExtraction` 的 `catch ArchiveError.wrongPassword` 分支(第 317 行附近)改为区分来源。找到:

```swift
            } catch ArchiveError.wrongPassword {
                passwordDraft = ""
                passwordError = "密码错误,请重试"
```

在其起始处插入分支判断——若本次是对话框发起(`options != nil`),则重弹对话框并内联报错,不走密码 sheet:

```swift
            } catch ArchiveError.wrongPassword {
                if options != nil {
                    extractDialogError = "密码错误,请重试"
                    showExtractDialog = true
                    return
                }
                passwordDraft = ""
                passwordError = "密码错误,请重试"
```

(其余 `passwordContext = .retryExtraction(...)` 等原有语句保持不变。)

- [ ] **Step 5: 右键菜单接对话框路**

`Sources/SevenZipApp/TwoPaneBrowserView.swift:179`,当前:

```swift
        Button("解压选中…") { onExtractSelected(ids) }
```

`onExtractSelected` 现走一键路。改为让宿主用对话框路:在 `App.swift` 里 `content` 的 `TwoPaneBrowserView(onExtractSelected:)` 闭包(第 263 行)改为:

```swift
                onExtractSelected: { ids in presentExtractDialog(paths: Array(ids)) }
```

(`TwoPaneBrowserView.swift` 本身文案已带省略号,无需改;仅改宿主闭包语义。)

- [ ] **Step 6: 构建验证**

Run: `make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: 手动验证(完整流程)**

Run: `make run`,逐项确认:
1. 「解压全部」主体点击 = 一键解压(不弹对话框)。
2. 「解压全部」右侧箭头 →「解压到…」→ 弹对话框;默认位置=包所在目录、到文件夹=智能名、排除重复根目录勾选、已存在时=询问。
3. 位置框填 `~/Downloads` → 预览行显示展开后的绝对路径;填不存在目录 → 红框 + 红字 +「解压」禁用。
4. 到文件夹填 `a/b` 或 `..` → 红框 + 红字 + 禁用;改回合法名 → 恢复。
5. 取消「到文件夹」勾选 → 黄色警告出现,「解压」仍可用;确认 → 文件铺进位置目录。
6. 改动位置/到文件夹后 → 对应 `arrow.clockwise` 出现,点击复位。
7. 「已存在时」选带序号 → 目标存在时自动落到 `名 2`;选删除原文件夹 → 覆盖。
8. 右键列表项「解压选中…」→ 弹对话框,范围为选中项。
9. (加密包)对话框内填错密码解压 → 对话框重新出现并显示「密码错误,请重试」。

- [ ] **Step 8: Commit**

```bash
git add Sources/SevenZipApp/App.swift Sources/SevenZipApp/TwoPaneBrowserView.swift
git commit -m "feat(ui): wire extract-to dialog into split-button menus and context menu"
```

---

## Self-Review

**Spec coverage:**
- §快慢双路 → Task 3(统一 extract)+ Task 5(分体菜单)。✓
- §覆盖粒度文件夹级/CollisionChoice → Task 3 的 overwriteMode switch。✓
- §目标模型(两输入框/浏览/dump)→ Task 4 视图 + Task 2 resolveDestination。✓
- §排除重复根目录开关 → Task 2(stripTopDir)+ Task 4(Toggle)。✓
- §已存在时下拉 → Task 2/3(numbered/deleteExisting)+ Task 4(Picker)。✓
- §校验哲学(不篡改/UI 反馈/双层防御)→ Task 1(validate)+ Task 2(resolve 抛错)+ Task 4(红框/禁用)。✓
- §还原默认(改过才现)→ Task 4(locationChanged/subfolderChanged)。✓
- §密码错误自包含 → Task 5 Step 4。✓
- §预览行防呆 → Task 4(previewPath)。✓
- §测试策略(乱填矩阵/回归parity)→ Task 1/2 测试。✓

**Placeholder scan:** 无 TBD/TODO;每个代码步骤含完整代码。✓

**Type consistency:** `ExtractOptions`/`OverwritePolicy`/`ResolvedDestination`/`ExtractValidationError` 字段与方法签名跨任务一致;`ExtractionController.extract` 新签名在 Task 3 定义、Task 5 消费一致;`runExtraction(selectedPaths:options:)` 定义于 Task 3、Task 5 消费。✓

## 计划偏移 / 待同步(与用户)

1. **默认子文件夹名**:spec §④ 写「包名」,实现取 `hasSingleTopLevelDirectory(entries) ?? archiveBaseName(archive)`(顶层目录名优先),以与旧一键行为**逐字节一致**、且回归测试可断言。当单顶层目录名 ≠ 包名时,对话框「到文件夹」预填的是顶层目录名。若你更希望恒为包名,一句话即可改(会放弃与旧行为的严格 parity)。
2. **strip 与「与包同名」**:你口述的 strip 规则含「与压缩包同名」限定,但**现有代码**的 `hasSingleTopLevelDirectory` 对任意单顶层目录都 strip,不作名字匹配。本计划按「保留原本逻辑」= 保留现有代码语义,未引入同名限定(YAGNI,且改它属行为变更、超出本 spec)。如需名字匹配另开小任务。

# 创建压缩包(Compression v1)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从散文件/文件夹创建 7z/zip 压缩包:一个 7zz 驱动的创建流程(选源 → 设置对话框 → 压缩 → 反馈)。

**Architecture:** `CompressionOptions` 是与 `ExtractOptions` 平行的纯值类型(validate / resolveOutput / defaults / commonParent / arguments 全部纯函数、可单测);`SevenZipRunner.compress` 组 `7zz a` 并按 `-bb1` 的 `+ ` 行数报确定进度;`CompressionController` 处理文件级碰撞/进度/反馈;`CreateArchiveView` 仿 `ExtractOptionsView`;入口用一个新的专用创建窗口 `WindowGroup(for: CreateArchiveRequest.self)`。

**Tech Stack:** Swift 6, SwiftUI, AppKit(NSOpenPanel), XCTest, XcodeGen + xcodebuild(`make build`),SPM(`swift test` 跑纯逻辑 + 集成)。

## Global Constraints

- 部署 macOS 14.0,`SWIFT_VERSION 6.0`,Sendable/@MainActor 正确。
- 新源文件由 XcodeGen 目录 glob 自动纳入,**不改 `project.yml`**。新 **app-target** 文件(`Sources/SevenZipApp/*.swift`)`make build` 前须 `xcodegen generate`;ArchiveKit 源码走 SPM 包(无需 regen);新 **测试** 文件 `swift test` 自动纳入(无需 regen)。
- 纯逻辑/集成测试:`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite>`(本机 xcode-select 指向 CommandLineTools,缺 XCTest,此前缀必需)。集成测试用 `/opt/homebrew/bin/7z`(`TestArchives.sevenZipURL`,与现有一致)。
- 面向用户文案:简体中文硬编码,无本地化。
- **永不篡改/拦截用户输入**;合法性只以 UI 反馈(红框/红字/禁用)体现。
- v1 格式仅 **7z + zip**;`-mhe` 仅 7z;zip 加密用 `-mem=AES256`;排除 dotfiles 用 `-xr!.*`;进度用 `-bb1` 的 `+ ` 行。
- Commit:英文 Conventional Commits;每个 Task 末尾 commit 一次。
- 我们在 `feat/compression` 分支;不在 master 提交;不提交 `Resources/7zz`。

---

### Task 1: `ArchiveFormat` + `CompressionLevel` + `CompressionOptions` + 校验(纯逻辑)

**Files:**
- Create: `Sources/ArchiveKit/CompressionOptions.swift`
- Test: `Tests/ArchiveKitTests/CompressionOptionsTests.swift`

**Interfaces:**
- Consumes(既有):`ArchiveError.invalidDestination(String)`。
- Produces:
  - `enum ArchiveFormat: String, Sendable, CaseIterable { case sevenZip="7z", zip="zip" }` + `fileExtension`/`typeFlag`/`supportsHeaderEncryption`
  - `enum CompressionLevel: Int, Sendable, CaseIterable { store=0, fastest=1, normal=5, maximum=7, ultra=9 }`
  - `enum CompressionValidationError: Equatable, Sendable { case noItems, outputDirectoryInvalid, invalidArchiveName }`
  - `struct CompressionOptions: Sendable`(字段见下)+ `init`
  - `func validate(fileManager:) -> [CompressionValidationError]`

- [ ] **Step 1: 写失败测试**

`Tests/ArchiveKitTests/CompressionOptionsTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class CompressionOptionsTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func opts(items: [URL], outDir: URL, name: String = "Archive",
                      format: ArchiveFormat = .sevenZip, level: CompressionLevel = .normal,
                      password: String = "", encryptHeader: Bool = true,
                      excludeDotfiles: Bool = true) -> CompressionOptions {
        CompressionOptions(items: items, outputDirectory: outDir, archiveName: name,
                           format: format, level: level, password: password,
                           encryptHeader: encryptHeader, excludeDotfiles: excludeDotfiles)
    }

    func test_format_extension_and_header_support() {
        XCTAssertEqual(ArchiveFormat.sevenZip.fileExtension, "7z")
        XCTAssertEqual(ArchiveFormat.zip.fileExtension, "zip")
        XCTAssertTrue(ArchiveFormat.sevenZip.supportsHeaderEncryption)
        XCTAssertFalse(ArchiveFormat.zip.supportsHeaderEncryption)
    }

    func test_validate_passes_for_items_writable_dir_clean_name() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt")
        try "x".write(to: item, atomically: true, encoding: .utf8)
        XCTAssertEqual(opts(items: [item], outDir: dir, name: "out").validate(), [])
    }

    func test_validate_flags_empty_items() throws {
        let dir = try tempDir()
        XCTAssertEqual(opts(items: [], outDir: dir, name: "out").validate(), [.noItems])
    }

    func test_validate_allows_nonexistent_output_dir_under_writable_parent() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        let newOut = dir.appendingPathComponent("new-\(UUID().uuidString)")
        XCTAssertEqual(opts(items: [item], outDir: newOut, name: "out").validate(), [])
    }

    func test_validate_flags_unwritable_root_output() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        let bad = URL(fileURLWithPath: "/no-such-root-\(UUID().uuidString)/x")
        XCTAssertEqual(opts(items: [item], outDir: bad, name: "out").validate(), [.outputDirectoryInvalid])
    }

    func test_validate_rejects_bad_archive_names() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        for bad in ["a/b", "a:b", ".", "..", "   "] {
            XCTAssertEqual(opts(items: [item], outDir: dir, name: bad).validate(), [.invalidArchiveName],
                           "expected \(bad) invalid")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CompressionOptionsTests`
Expected: FAIL(类型未定义)

- [ ] **Step 3: 写 `CompressionOptions.swift`**

`Sources/ArchiveKit/CompressionOptions.swift`:

```swift
import Foundation

/// v1 支持的输出格式(7zz `i` 中带 C 标志、且原生支持多文件/文件夹的:仅 7z / zip)。
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case sevenZip = "7z"
    case zip = "zip"
    public var fileExtension: String { rawValue }
    public var typeFlag: String { rawValue }            // 7zz -t<...>
    public var supportsHeaderEncryption: Bool { self == .sevenZip }   // -mhe 仅 7z
}

/// 压缩等级 → 7zz -mx=<rawValue>。
public enum CompressionLevel: Int, Sendable, CaseIterable {
    case store = 0
    case fastest = 1
    case normal = 5
    case maximum = 7
    case ultra = 9
}

public enum CompressionValidationError: Equatable, Sendable {
    case noItems
    case outputDirectoryInvalid    // 最近的已存在祖先不是可写目录
    case invalidArchiveName
}

/// 「创建压缩包」对话框的输出;含可单测的纯逻辑。
public struct CompressionOptions: Sendable {
    public var items: [URL]             // 源(绝对路径)
    public var outputDirectory: URL     // 保存到(容器,已归一)
    public var archiveName: String      // 不含扩展名
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String
    public var encryptHeader: Bool      // -mhe;仅 7z + 有密码时生效
    public var excludeDotfiles: Bool

    public init(items: [URL], outputDirectory: URL, archiveName: String,
                format: ArchiveFormat, level: CompressionLevel, password: String,
                encryptHeader: Bool, excludeDotfiles: Bool) {
        self.items = items
        self.outputDirectory = outputDirectory
        self.archiveName = archiveName
        self.format = format
        self.level = level
        self.password = password
        self.encryptHeader = encryptHeader
        self.excludeDotfiles = excludeDotfiles
    }

    /// 纯校验。输出目录可不存在(压缩时创建),但最近的已存在祖先须为可写目录
    /// (镜像 ExtractOptions 放宽版位置校验)。压缩包名须为单一合法路径分量(非空)。
    public func validate(fileManager fm: FileManager = .default) -> [CompressionValidationError] {
        var errors: [CompressionValidationError] = []
        if items.isEmpty { errors.append(.noItems) }

        var probe = outputDirectory
        var isDir: ObjCBool = false
        while !fm.fileExists(atPath: probe.path, isDirectory: &isDir) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        if !isDir.boolValue || !fm.isWritableFile(atPath: probe.path) {
            errors.append(.outputDirectoryInvalid)
        }

        let name = archiveName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":") {
            errors.append(.invalidArchiveName)
        }
        return errors
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CompressionOptionsTests`
Expected: PASS(6 个用例)

- [ ] **Step 5: Commit**

```bash
git add Sources/ArchiveKit/CompressionOptions.swift Tests/ArchiveKitTests/CompressionOptionsTests.swift
git commit -m "feat(archivekit): CompressionOptions value type with format/level and validation"
```

---

### Task 2: 源映射 / 默认 / 输出解析 / 参数组装 / 文件计数(纯逻辑)

**Files:**
- Modify: `Sources/ArchiveKit/CompressionOptions.swift`
- Create: `Sources/ArchiveKit/CompressionProgress.swift`
- Test: `Tests/ArchiveKitTests/CompressionOptionsTests.swift`(追加)

**Interfaces:**
- Consumes(Task 1):`CompressionOptions`、`ArchiveFormat`、`CompressionLevel`、`ArchiveError.invalidDestination`。
- Produces:
  - `static func CompressionOptions.commonParent(of items: [URL]) -> URL`
  - `var CompressionOptions.relativeItemPaths: [String]`
  - `static func CompressionOptions.defaults(items: [URL]) -> CompressionOptions`
  - `func CompressionOptions.resolveOutput(fileManager:) throws -> URL`
  - `static func CompressionOptions.numberedFile(base: URL, exists: (URL) -> Bool) -> URL`
  - `func CompressionOptions.arguments(output: URL) -> [String]`
  - `enum CompressionProgress { static func totalFileCount(items:excludeDotfiles:fileManager:) -> Int }`

- [ ] **Step 1: 写失败测试(追加到 CompressionOptionsTests)**

```swift
    func test_commonParent_same_dir_multi() {
        let base = URL(fileURLWithPath: "/a/b")
        let items = [base.appendingPathComponent("x"), base.appendingPathComponent("y")]
        XCTAssertEqual(CompressionOptions.commonParent(of: items).path, "/a/b")
    }

    func test_commonParent_single_item_is_parent() {
        let items = [URL(fileURLWithPath: "/a/b/x")]
        XCTAssertEqual(CompressionOptions.commonParent(of: items).path, "/a/b")
    }

    func test_commonParent_cross_dir() {
        let items = [URL(fileURLWithPath: "/a/b/x/deep"), URL(fileURLWithPath: "/a/b/y")]
        XCTAssertEqual(CompressionOptions.commonParent(of: items).path, "/a/b")
    }

    func test_relativeItemPaths_same_dir() {
        let base = URL(fileURLWithPath: "/a/b")
        let items = [base.appendingPathComponent("x"), base.appendingPathComponent("y")]
        XCTAssertEqual(opts(items: items, outDir: base).relativeItemPaths, ["x", "y"])
    }

    func test_relativeItemPaths_cross_dir_preserves_structure() {
        let items = [URL(fileURLWithPath: "/a/b/x/deep"), URL(fileURLWithPath: "/a/b/y")]
        XCTAssertEqual(opts(items: items, outDir: URL(fileURLWithPath: "/a/b")).relativeItemPaths, ["x/deep", "y"])
    }

    func test_defaults_single_folder_names_after_it() throws {
        let parent = try tempDir()
        let folder = parent.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let d = CompressionOptions.defaults(items: [folder])
        XCTAssertEqual(d.archiveName, "proj")
        XCTAssertEqual(d.outputDirectory.path, parent.path)
        XCTAssertEqual(d.format, .sevenZip)
        XCTAssertEqual(d.level, .normal)
        XCTAssertTrue(d.encryptHeader)
        XCTAssertTrue(d.excludeDotfiles)
    }

    func test_defaults_single_file_keeps_original_name() {
        let d = CompressionOptions.defaults(items: [URL(fileURLWithPath: "/a/b/a.txt")])
        XCTAssertEqual(d.archiveName, "a.txt")
    }

    func test_defaults_multi_uses_parent_dir_name() {
        let items = [URL(fileURLWithPath: "/a/b/x"), URL(fileURLWithPath: "/a/b/y")]
        XCTAssertEqual(CompressionOptions.defaults(items: items).archiveName, "b")
    }

    func test_resolveOutput_appends_extension() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        let out7z = try opts(items: [item], outDir: dir, name: "pack", format: .sevenZip).resolveOutput()
        XCTAssertEqual(out7z, dir.appendingPathComponent("pack.7z"))
        let outzip = try opts(items: [item], outDir: dir, name: "pack", format: .zip).resolveOutput()
        XCTAssertEqual(outzip, dir.appendingPathComponent("pack.zip"))
    }

    func test_resolveOutput_throws_on_invalid() {
        let bad = URL(fileURLWithPath: "/no-root-\(UUID().uuidString)/x")
        XCTAssertThrowsError(try opts(items: [URL(fileURLWithPath: "/a/x")], outDir: bad, name: "p").resolveOutput()) { e in
            guard case ArchiveError.invalidDestination = e else { return XCTFail("expected invalidDestination") }
        }
    }

    func test_numberedFile_inserts_before_extension() {
        var existing: Set<String> = ["/d/Archive.7z", "/d/Archive 2.7z"]
        let out = CompressionOptions.numberedFile(base: URL(fileURLWithPath: "/d/Archive.7z"),
                                                  exists: { existing.contains($0.path) })
        XCTAssertEqual(out, URL(fileURLWithPath: "/d/Archive 3.7z"))
        _ = existing
    }

    func test_arguments_7z_with_password_and_header_and_dotfiles() {
        let base = URL(fileURLWithPath: "/a/b")
        let o = opts(items: [base.appendingPathComponent("x")], outDir: base, name: "p",
                     format: .sevenZip, level: .maximum, password: "PW",
                     encryptHeader: true, excludeDotfiles: true)
        let args = o.arguments(output: URL(fileURLWithPath: "/a/b/p.7z"))
        XCTAssertEqual(args, ["a", "-t7z", "-mx=7", "-bb1", "-y", "-pPW", "-mhe=on", "-xr!.*", "/a/b/p.7z", "x"])
    }

    func test_arguments_zip_uses_aes_not_mhe() {
        let base = URL(fileURLWithPath: "/a/b")
        let o = opts(items: [base.appendingPathComponent("x")], outDir: base, name: "p",
                     format: .zip, level: .normal, password: "PW",
                     encryptHeader: true, excludeDotfiles: false)
        let args = o.arguments(output: URL(fileURLWithPath: "/a/b/p.zip"))
        XCTAssertEqual(args, ["a", "-tzip", "-mx=5", "-bb1", "-y", "-pPW", "-mem=AES256", "/a/b/p.zip", "x"])
    }

    func test_arguments_no_password_no_encryption_flags() {
        let base = URL(fileURLWithPath: "/a/b")
        let o = opts(items: [base.appendingPathComponent("x")], outDir: base, name: "p",
                     format: .sevenZip, level: .store, password: "", excludeDotfiles: false)
        let args = o.arguments(output: URL(fileURLWithPath: "/a/b/p.7z"))
        XCTAssertEqual(args, ["a", "-t7z", "-mx=0", "-bb1", "-y", "/a/b/p.7z", "x"])
    }

    func test_totalFileCount_counts_regular_files_skipping_dotfiles() throws {
        let dir = try tempDir()
        let sub = dir.appendingPathComponent("s"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("f1.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: sub.appendingPathComponent("f2.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CompressionProgress.totalFileCount(items: [dir], excludeDotfiles: true), 2)
        XCTAssertEqual(CompressionProgress.totalFileCount(items: [dir], excludeDotfiles: false), 3)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CompressionOptionsTests`
Expected: FAIL(新方法未定义)

- [ ] **Step 3: 追加纯逻辑到 `CompressionOptions.swift`**

在 `Sources/ArchiveKit/CompressionOptions.swift` 末尾追加:

```swift
extension CompressionOptions {
    /// 所有 item 的最深公共目录(压缩的工作目录 + 相对路径基准)。
    /// 单项 → 其父目录;同目录多项 → 该目录;跨目录 → 最深公共祖先。
    public static func commonParent(of items: [URL]) -> URL {
        let comps = items.map { $0.standardizedFileURL.pathComponents }
        guard let first = comps.first else { return URL(fileURLWithPath: "/") }
        var prefix: [String] = []
        for (i, c) in first.enumerated() {
            if comps.allSatisfy({ i < $0.count && $0[i] == c }) { prefix.append(c) } else { break }
        }
        var url = URL(fileURLWithPath: "/")
        for c in prefix.dropFirst() { url.appendPathComponent(c) }   // dropFirst 跳过 "/"
        // 若公共前缀恰好等于某个 item(单项,或某项是其他项的祖先),上移一层到容器目录。
        if items.contains(where: { $0.standardizedFileURL.pathComponents == prefix }) {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// 各 item 相对公共父目录的路径(传给 7zz,working dir = 公共父目录)。
    public var relativeItemPaths: [String] {
        let base = CompressionOptions.commonParent(of: items).standardizedFileURL.pathComponents
        return items.map { item in
            item.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
        }
    }

    /// 一键默认。单项 → 该项名字;多项 → 公共父目录名(取不到则 "Archive")。
    public static func defaults(items: [URL]) -> CompressionOptions {
        let parent = commonParent(of: items)
        let name: String
        if items.count == 1 {
            name = items[0].lastPathComponent
        } else {
            let p = parent.lastPathComponent
            name = (p.isEmpty || p == "/") ? "Archive" : p
        }
        return CompressionOptions(items: items, outputDirectory: parent, archiveName: name,
                                  format: .sevenZip, level: .normal, password: "",
                                  encryptHeader: true, excludeDotfiles: true)
    }

    /// 最终输出 URL:`outputDirectory/(name).<ext>`。非法则 fail-fast 抛 invalidDestination。
    public func resolveOutput(fileManager fm: FileManager = .default) throws -> URL {
        guard validate(fileManager: fm).isEmpty else {
            throw ArchiveError.invalidDestination("输出目录或压缩包名无效")
        }
        let name = archiveName.trimmingCharacters(in: .whitespaces)
        return outputDirectory.appendingPathComponent("\(name).\(format.fileExtension)")
    }

    /// 带序号变体(插在扩展名之前):Archive.7z → Archive 2.7z。
    public static func numberedFile(base: URL, exists: (URL) -> Bool) -> URL {
        guard exists(base) else { return base }
        let dir = base.deletingLastPathComponent()
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        func candidate(_ n: Int) -> URL {
            let nm = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            return dir.appendingPathComponent(nm)
        }
        var n = 2
        var c = candidate(n)
        while exists(c) { n += 1; c = candidate(n) }
        return c
    }

    /// 组装 `7zz a` 参数。output 用绝对路径;items 用相对公共父目录的路径(配合 working dir)。
    public func arguments(output: URL) -> [String] {
        var args = ["a", "-t\(format.typeFlag)", "-mx=\(level.rawValue)", "-bb1", "-y"]
        if !password.isEmpty {
            args.append("-p\(password)")
            if format == .sevenZip && encryptHeader { args.append("-mhe=on") }
            if format == .zip { args.append("-mem=AES256") }
        }
        if excludeDotfiles { args.append("-xr!.*") }
        args.append(output.path)
        args.append(contentsOf: relativeItemPaths)
        return args
    }
}
```

- [ ] **Step 4: 写 `CompressionProgress.swift`**

`Sources/ArchiveKit/CompressionProgress.swift`:

```swift
import Foundation

public enum CompressionProgress {
    /// 7zz 将写入的常规文件数,作进度分母。镜像 `-xr!.*`:excludeDotfiles 时跳过
    /// 任何含点前缀分量的路径。best-effort——进度条另有 min(1,…) 封顶,分母略偏无碍。
    public static func totalFileCount(items: [URL], excludeDotfiles: Bool,
                                      fileManager fm: FileManager = .default) -> Int {
        var count = 0
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if !(excludeDotfiles && item.lastPathComponent.hasPrefix(".")) { count += 1 }
                continue
            }
            guard let en = fm.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            while let url = en.nextObject() as? URL {
                if excludeDotfiles && url.pathComponents.contains(where: { $0 != "/" && $0.hasPrefix(".") }) {
                    continue
                }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    count += 1
                }
            }
        }
        return count
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CompressionOptionsTests`
Expected: PASS(全部,含 Task 1 的 6 + 本任务 14)

- [ ] **Step 6: Commit**

```bash
git add Sources/ArchiveKit/CompressionOptions.swift Sources/ArchiveKit/CompressionProgress.swift Tests/ArchiveKitTests/CompressionOptionsTests.swift
git commit -m "feat(archivekit): compression source mapping, defaults, argument assembly, file count"
```

---

### Task 3: `SevenZipRunner.compress`(后端 + 集成测试)

**Files:**
- Modify: `Sources/ArchiveKit/SevenZipRunner.swift`
- Test: `Tests/ArchiveKitTests/SevenZipRunnerCompressTests.swift`

**Interfaces:**
- Consumes:`CompressionOptions`(仅用于组 args,测试里直接给 args)、既有 `RunResult`/`runStreaming`。
- Produces:
  - `static func SevenZipRunner.isAddedLine(_ line: String) -> Bool`
  - `func SevenZipRunner.compress(arguments: [String], workingDirectory: URL, onFileAdded: (@Sendable () -> Void)?) throws`
  - `runStreaming` 增加可选 `workingDirectory` 参数(既有调用不受影响)。

- [ ] **Step 1: 写失败测试**

`Tests/ArchiveKitTests/SevenZipRunnerCompressTests.swift`:

```swift
import XCTest
@testable import ArchiveKit

final class SevenZipRunnerCompressTests: XCTestCase {
    let runner = SevenZipRunner(executableURL: TestArchives.sevenZipURL)

    func test_isAddedLine() {
        XCTAssertTrue(SevenZipRunner.isAddedLine("+ src/a.txt"))
        XCTAssertFalse(SevenZipRunner.isAddedLine("Everything is Ok"))
        XCTAssertFalse(SevenZipRunner.isAddedLine("Files read from disk: 3"))
    }

    /// Compress a folder to 7z, then list it back and assert entries + relative paths.
    func test_compress_7z_writes_expected_entries() throws {
        let dir = try TestArchives.makeTempDir()
        let src = dir.appendingPathComponent("src/sub")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hi".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "d".write(to: dir.appendingPathComponent("src/.DS_Store"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out.7z")

        var added = 0
        try runner.compress(
            arguments: ["a", "-t7z", "-mx=1", "-bb1", "-y", "-xr!.*", out.path, "src"],
            workingDirectory: dir,
            onFileAdded: { added += 1 })

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let paths = try runner.list(archive: out, password: nil).map(\.path)
        XCTAssertTrue(paths.contains("src/sub/a.txt"))
        XCTAssertFalse(paths.contains("src/.DS_Store"))   // dotfile excluded
        XCTAssertEqual(added, 1)                          // one regular file added
    }

    /// Header-encrypted 7z needs a password even to list.
    func test_compress_7z_header_encrypted() throws {
        let dir = try TestArchives.makeTempDir()
        try "secret".write(to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("enc.7z")
        try runner.compress(
            arguments: ["a", "-t7z", "-mx=1", "-bb1", "-y", "-pPW", "-mhe=on", out.path, "s.txt"],
            workingDirectory: dir, onFileAdded: nil)
        XCTAssertThrowsError(try runner.list(archive: out, password: nil)) { e in
            XCTAssertEqual(e as? ArchiveError, .needsPassword)
        }
        XCTAssertTrue(try runner.list(archive: out, password: "PW").map(\.path).contains("s.txt"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SevenZipRunnerCompressTests`
Expected: FAIL(`compress`/`isAddedLine` 未定义)

- [ ] **Step 3: 给 `runStreaming` 加 workingDirectory 参数**

`Sources/ArchiveKit/SevenZipRunner.swift`,把 `runStreaming` 的声明行改为(仅新增一个默认参数):

```swift
    private func runStreaming(_ arguments: [String], workingDirectory: URL? = nil,
                             onLine: @Sendable (String) -> Void) throws -> RunResult {
```

并在其中 `process.arguments = arguments` 之后插入一行:

```swift
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
```

- [ ] **Step 4: 加 `isAddedLine` + `compress`**

在 `Sources/ArchiveKit/SevenZipRunner.swift` 的 `isEntryLine` 静态方法附近追加:

```swift
    /// True when a `7zz a -bb1` output line announces an added file (`+ some/path`).
    /// Directories are not logged; only regular files get a `+` line.
    public static func isAddedLine(_ line: String) -> Bool {
        line.hasPrefix("+ ")
    }
```

在 `class` 内(如 extract 方法之后)追加 compress:

```swift
    /// Runs `7zz a` with the given args in `workingDirectory` (so items are stored by
    /// their relative paths). `onFileAdded` fires once per added regular file (`-bb1`).
    public func compress(arguments: [String], workingDirectory: URL,
                         onFileAdded: (@Sendable () -> Void)? = nil) throws {
        let result = try runStreaming(arguments, workingDirectory: workingDirectory) { line in
            if SevenZipRunner.isAddedLine(line) { onFileAdded?() }
        }
        guard result.code == 0 else {
            let combined = result.stdout + result.stderr
            throw ArchiveError.executionFailed(
                code: result.code,
                message: combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SevenZipRunnerCompressTests`
Expected: PASS(3 个用例)

- [ ] **Step 6: 跑全 ArchiveKit 套件确认无回归**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS(既有全部 + 新增)

- [ ] **Step 7: Commit**

```bash
git add Sources/ArchiveKit/SevenZipRunner.swift Tests/ArchiveKitTests/SevenZipRunnerCompressTests.swift
git commit -m "feat(archivekit): SevenZipRunner.compress with per-file progress and workdir"
```

---

### Task 4: `CompressionController`(App 层)

**Files:**
- Create: `Sources/SevenZipApp/CompressionController.swift`
- Modify: `Sources/SevenZipApp/ExtractionController.swift`(把 `ProgressCounter` 由 `private` 改 internal 以复用)

**Interfaces:**
- Consumes:`CompressionOptions`(`resolveOutput`/`arguments`/`commonParent`/`numberedFile`)、`CompressionProgress.totalFileCount`、`SevenZipRunner.compress`、既有 `CollisionChoice`、`ProgressCounter`。
- Produces:`CompressionController.compress(options:resolveCollision:onProgress:) async throws -> URL`。

- [ ] **Step 1: 放开 `ProgressCounter` 可见性**

`Sources/SevenZipApp/ExtractionController.swift`,把:

```swift
private final class ProgressCounter: @unchecked Sendable {
```

改为(去掉 `private`,同文件其余不变):

```swift
final class ProgressCounter: @unchecked Sendable {
```

- [ ] **Step 2: 写 `CompressionController.swift`**

`Sources/SevenZipApp/CompressionController.swift`:

```swift
import Foundation
import ArchiveKit

/// Resolves output path per options, handles file-level collision, then compresses.
/// Parallels ExtractionController; reuses CollisionChoice and ProgressCounter.
@MainActor
final class CompressionController {
    private let runner: SevenZipRunner
    init(runner: SevenZipRunner) { self.runner = runner }

    func compress(
        options: CompressionOptions,
        resolveCollision: (URL) async -> CollisionChoice,
        onProgress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        var output = try options.resolveOutput()

        if fm.fileExists(atPath: output.path) {
            switch await resolveCollision(output) {
            case .cancel:
                throw CancellationError()
            case .deleteExisting:
                try fm.removeItem(at: output)
            case .numbered:
                output = CompressionOptions.numberedFile(base: output,
                                                         exists: { fm.fileExists(atPath: $0.path) })
            }
        }

        let total = CompressionProgress.totalFileCount(items: options.items,
                                                       excludeDotfiles: options.excludeDotfiles)
        onProgress(0, total)

        let runner = self.runner
        let out = output
        let args = options.arguments(output: out)
        let workdir = CompressionOptions.commonParent(of: options.items)
        let counter = ProgressCounter()
        try await Task.detached {
            try runner.compress(arguments: args, workingDirectory: workdir, onFileAdded: {
                let done = counter.increment()
                Task { @MainActor in onProgress(done, total) }
            })
        }.value
        return output
    }
}
```

- [ ] **Step 3: 构建验证**

Run: `make build`
Expected: BUILD SUCCEEDED(仅改现有 app 文件 + ArchiveKit 已含新类型,无需 regen;`CompressionController.swift` 是新 app 文件 → **需先** `xcodegen generate`)

实际命令:`xcodegen generate && make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 跑纯套件确认无回归**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CompressionOptionsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SevenZipApp/CompressionController.swift Sources/SevenZipApp/ExtractionController.swift
git commit -m "feat(app): CompressionController with file-level collision and progress"
```

---

### Task 5: `CreateArchiveView` 对话框

**Files:**
- Create: `Sources/SevenZipApp/CreateArchiveView.swift`

**Interfaces:**
- Consumes:`CompressionOptions`、`ArchiveFormat`、`CompressionLevel`、`CompressionValidationError`、`resolveOutput`、`validate`。
- Produces:`struct CreateArchiveView: View`,init 参数
  `(defaults: CompressionOptions, onCreate: (CompressionOptions) -> Void, onCancel: () -> Void)`。

- [ ] **Step 1: 写视图**

`Sources/SevenZipApp/CreateArchiveView.swift`:

```swift
import SwiftUI
import AppKit
import ArchiveKit

/// 「创建压缩包」对话框。只做输入 + 实时反馈,不含压缩逻辑;确认后把编辑好的
/// CompressionOptions 交回调用方(仿 ExtractOptionsView)。
struct CreateArchiveView: View {
    let defaults: CompressionOptions
    let onCreate: (CompressionOptions) -> Void
    let onCancel: () -> Void

    @State private var outputDirText: String
    @State private var archiveName: String
    @State private var format: ArchiveFormat
    @State private var level: CompressionLevel
    @State private var password: String
    @State private var showPassword = false
    @State private var encryptHeader: Bool
    @State private var excludeDotfiles: Bool

    init(defaults: CompressionOptions, onCreate: @escaping (CompressionOptions) -> Void,
         onCancel: @escaping () -> Void) {
        self.defaults = defaults
        self.onCreate = onCreate
        self.onCancel = onCancel
        _outputDirText = State(initialValue: defaults.outputDirectory.path)
        _archiveName = State(initialValue: defaults.archiveName)
        _format = State(initialValue: defaults.format)
        _level = State(initialValue: defaults.level)
        _password = State(initialValue: defaults.password)
        _encryptHeader = State(initialValue: defaults.encryptHeader)
        _excludeDotfiles = State(initialValue: defaults.excludeDotfiles)
    }

    private var currentOptions: CompressionOptions {
        CompressionOptions(items: defaults.items,
                           outputDirectory: URL(fileURLWithPath: (outputDirText as NSString).expandingTildeInPath).standardizedFileURL,
                           archiveName: archiveName, format: format, level: level,
                           password: password, encryptHeader: encryptHeader,
                           excludeDotfiles: excludeDotfiles)
    }
    private var errors: [CompressionValidationError] { currentOptions.validate() }
    private var outputInvalid: Bool { errors.contains(.outputDirectoryInvalid) }
    private var nameInvalid: Bool { errors.contains(.invalidArchiveName) }
    private var previewPath: String { (try? currentOptions.resolveOutput())?.path ?? "—" }
    private var showHeaderToggle: Bool { format == .sevenZip && !password.isEmpty }
    private var outputChanged: Bool { outputDirText != defaults.outputDirectory.path }
    private var nameChanged: Bool { archiveName != defaults.archiveName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("创建压缩包").font(.headline)
            Text("\(defaults.items.count) 项:\(defaults.items.map(\.lastPathComponent).joined(separator: "、"))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)

            outputRow
            nameRow

            Picker("格式", selection: $format) {
                Text("7z").tag(ArchiveFormat.sevenZip)
                Text("zip").tag(ArchiveFormat.zip)
            }
            .pickerStyle(.segmented).frame(maxWidth: 200, alignment: .leading)

            Picker("压缩等级", selection: $level) {
                Text("仅存储").tag(CompressionLevel.store)
                Text("最快").tag(CompressionLevel.fastest)
                Text("普通").tag(CompressionLevel.normal)
                Text("最好").tag(CompressionLevel.maximum)
                Text("极限").tag(CompressionLevel.ultra)
            }
            .pickerStyle(.menu).frame(maxWidth: 260, alignment: .leading)

            passwordRow
            if showHeaderToggle {
                Toggle("加密文件名/头", isOn: $encryptHeader)
            }
            Toggle("排除 dotfiles(.DS_Store 等)", isOn: $excludeDotfiles)

            previewAndWarnings

            Divider()
            HStack {
                Spacer()
                Button("取消") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("创建") { onCreate(currentOptions) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!errors.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("保存到").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $outputDirText)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(outputInvalid ? Color.red : Color.clear, lineWidth: 1))
                if outputChanged {
                    Button { outputDirText = defaults.outputDirectory.path } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("还原默认")
                }
                Button("…") { browseForOutputDir() }
            }
        }
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("压缩包名").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: $archiveName)
                    .textFieldStyle(.roundedBorder)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(nameInvalid ? Color.red : Color.clear, lineWidth: 1))
                if nameChanged {
                    Button { archiveName = defaults.archiveName } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("还原默认")
                }
                Text(".\(format.fileExtension)").foregroundStyle(.secondary)
            }
        }
    }

    private var passwordRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("密码(留空=不加密)").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if showPassword { TextField("", text: $password) }
                    else { SecureField("", text: $password) }
                }
                .textFieldStyle(.roundedBorder)
                Toggle("显示密码", isOn: $showPassword).toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var previewAndWarnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将创建:\(previewPath)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if nameInvalid {
                Label("压缩包名不能为空,且不能包含 / 或 :,也不能是 . 或 ..", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if outputInvalid {
                Label("保存位置无效:上层路径需为可写的目录", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func browseForOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (outputDirText as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { outputDirText = url.path }
    }
}
```

- [ ] **Step 2: 构建验证**

Run: `xcodegen generate && make build`
Expected: BUILD SUCCEEDED(新 app 文件已纳入编译;此时尚未接线)

- [ ] **Step 3: Commit**

```bash
git add Sources/SevenZipApp/CreateArchiveView.swift
git commit -m "feat(ui): create-archive dialog with live validation and preview"
```

---

### Task 6: 入口接线(创建窗 + ⌘N + 欢迎按钮 + 进度/反馈)

**Files:**
- Modify: `Sources/SevenZipApp/App.swift`
- Modify: `Sources/SevenZipApp/ExtractionProgressOverlay.swift`(overlay 加可选 `title`)

**Interfaces:**
- Consumes:`CreateArchiveView`、`CompressionOptions.defaults`、`CompressionController`、`ExtractionProgressOverlay`、`ExtractionProgressState`、`SevenZipLocator.bundledRunner()`、`ToastState`、`CollisionChoice`、`PostExtractAction`。

- [ ] **Step 1: 给进度覆盖层加可选标题**

`Sources/SevenZipApp/ExtractionProgressOverlay.swift`,把 `struct ExtractionProgressOverlay` 改为带标题(默认解压,压缩时传「正在压缩」):

将

```swift
struct ExtractionProgressOverlay: View {
    let state: ExtractionProgressState

    var body: some View {
```

改为

```swift
struct ExtractionProgressOverlay: View {
    let state: ExtractionProgressState
    var title: String = "正在解压"

    var body: some View {
```

并把体内两处文案

```swift
                    Text("正在解压…")
```
```swift
                    Text("正在解压… \(Int(fraction * 100))%")
```

改为

```swift
                    Text("\(title)…")
```
```swift
                    Text("\(title)… \(Int(fraction * 100))%")
```

(既有 `ArchiveWindow` 用法不传 title → 仍是「正在解压」,不变。)

- [ ] **Step 2: 加创建请求类型 + 源选择面板 + 菜单项**

`Sources/SevenZipApp/App.swift`,在文件顶部 `presentArchiveOpenPanel()` 之后追加源选择面板与请求类型:

```swift
/// A create-archive request carried by the create WindowGroup. Codable+Hashable so it
/// can be a SwiftUI window value; items are the user-selected files/folders.
struct CreateArchiveRequest: Codable, Hashable {
    var items: [URL]
}

/// Picks multiple files AND folders to compress. Returns [] if cancelled/empty.
@MainActor
func presentSourceOpenPanel() -> [URL] {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK else { return [] }
    return panel.urls
}
```

在 `SevenZipSwiftUIApp` 的 `.commands { CommandGroup(replacing: .newItem) { … } }` 里,「打开…」按钮之后追加「新建压缩包…」:

```swift
                Button("新建压缩包…") {
                    let items = presentSourceOpenPanel()
                    if !items.isEmpty { openWindow(value: CreateArchiveRequest(items: items)) }
                }
                .keyboardShortcut("n")
```

- [ ] **Step 3: 加创建 WindowGroup + 窗口视图**

`Sources/SevenZipApp/App.swift`,在 `SevenZipSwiftUIApp.body` 里,现有 `WindowGroup(for: URL.self) { … }` 之后、`.commands` 之前追加第二个 WindowGroup:

```swift
        WindowGroup(for: CreateArchiveRequest.self) { $request in
            if let request {
                CreateArchiveWindow(items: request.items)
            }
        }
```

并在 `App.swift` 末尾(或 `ArchiveWindow` 附近)追加窗口视图:

```swift
/// Hosts the create-archive dialog, progress overlay, collision dialog and feedback.
struct CreateArchiveWindow: View {
    let items: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var isCompressing = false
    @State private var progress: ExtractionProgressState?
    @State private var collisionURL: URL?
    @State private var collisionContinuation: CheckedContinuation<CollisionChoice, Never>?
    @State private var compressError: String?
    @AppStorage("postExtractAction") private var postExtractAction: PostExtractAction = .revealInFinder
    private let controller = CompressionController(runner: SevenZipLocator.bundledRunner())

    var body: some View {
        CreateArchiveView(
            defaults: CompressionOptions.defaults(items: items),
            onCreate: { opts in runCompression(opts) },
            onCancel: { dismiss() }
        )
        .overlay { if let progress { ExtractionProgressOverlay(state: progress, title: "正在压缩") } }
        .confirmationDialog(
            "压缩包已存在",
            isPresented: Binding(get: { collisionURL != nil }, set: { if !$0 { finishCollision(.cancel) } })
        ) {
            Button("保存为带序号的新名称") { finishCollision(.numbered) }
            Button("覆盖", role: .destructive) { finishCollision(.deleteExisting) }
            Button("取消", role: .cancel) { finishCollision(.cancel) }
        } message: { Text(collisionURL?.lastPathComponent ?? "") }
        .alert("压缩失败", isPresented: Binding(get: { compressError != nil }, set: { if !$0 { compressError = nil } })) {
            Button("好", role: .cancel) { compressError = nil }
        } message: { Text(compressError ?? "") }
    }

    private func finishCollision(_ choice: CollisionChoice) {
        collisionURL = nil
        collisionContinuation?.resume(returning: choice)
        collisionContinuation = nil
    }

    private func runCompression(_ options: CompressionOptions) {
        guard !isCompressing else { return }
        isCompressing = true
        Task {
            defer { isCompressing = false; progress = nil }
            do {
                let out = try await controller.compress(
                    options: options,
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
                case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([out])
                case .notify, .none: break
                }
                dismiss()
            } catch is CancellationError {
                // user cancelled the collision dialog — stay on the dialog
            } catch {
                compressError = "\(error)"
            }
        }
    }
}
```

- [ ] **Step 4: 欢迎窗加「创建压缩包…」按钮**

`Sources/SevenZipApp/App.swift` 的 `WelcomeView.body`,在现有「打开压缩包…」按钮之后追加:

```swift
            Button("创建压缩包…") {
                let items = presentSourceOpenPanel()
                if !items.isEmpty { openWindow(value: CreateArchiveRequest(items: items)) }
            }
```

(`WelcomeView` 已有 `@Environment(\.openWindow) private var openWindow`,可直接用。)

- [ ] **Step 5: 构建验证**

Run: `xcodegen generate && make build`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: 手动验证(完整流程)**

Run: `make run`,逐项确认:
1. 欢迎窗出现「创建压缩包…」按钮;文件菜单有「新建压缩包…」(⌘N)。
2. ⌘N / 按钮 → 弹多选面板(可同时选文件和文件夹)→ 选中后弹创建对话框。
3. 对话框:保存到=源所在目录、包名=智能默认、格式 7z、等级普通、排除 dotfiles 勾选;切到 zip 后包名右侧扩展名变 `.zip`、预览行同步。
4. 填密码 → 出现「加密文件名/头」勾选(仅 7z);切 zip 时该勾选消失。
5. 保存位置填不存在目录 → 无红字(将创建);填不可写根 → 红框+红字+「创建」禁用。包名清空或填 `a/b` → 红框+禁用。
6. 点「创建」→ 进度覆盖层显示「正在压缩… N%」→ 成功后按设置打开 Finder 并关窗;生成的包能被本应用打开、条目正确、dotfiles 已排除。
7. 同名已存在 → 弹「压缩包已存在」→ 带序号/覆盖/取消 各生效。
8. 加密包(7z+密码+加密头)用本应用打开需密码。

- [ ] **Step 7: Commit**

```bash
git add Sources/SevenZipApp/App.swift Sources/SevenZipApp/ExtractionProgressOverlay.swift
git commit -m "feat(app): wire create-archive flow — window, menu (Cmd-N), welcome button, progress"
```

---

## Self-Review

**Spec coverage:**
- §入口(欢迎按钮 + ⌘N) → Task 6。✓ Finder 集成明确为 v1 非目标。
- §格式 7z+zip → Task 1(ArchiveFormat)+ Task 2(arguments)。✓
- §核心字段 + `-mhe` → Task 5(视图)+ Task 2(arguments,`-mhe` 仅 7z / zip AES)。✓
- §排除 dotfiles 默认开 → Task 2(`-xr!.*`)+ Task 5(默认勾选)。✓
- §源映射(公共父目录相对路径)+ 默认命名 → Task 2(commonParent/relativeItemPaths/defaults)。✓
- §后端 compress + 进度(`-bb1` 计数)→ Task 3。✓
- §控制器 + 文件级碰撞 + 反馈 → Task 4 + Task 6。✓
- §窗口方案(CreateArchiveRequest WindowGroup) → Task 6。✓
- §防呆(不拦输入/UI 反馈/双层防御/预览/还原) → Task 5 + Task 1/2(validate + resolveOutput 抛错)。✓
- §测试(纯逻辑矩阵 + 集成) → Task 1/2/3 测试。✓

**Placeholder scan:** 无 TBD/TODO;每个代码步骤含完整代码。✓

**Type consistency:** `CompressionOptions`/`ArchiveFormat`/`CompressionLevel`/`CompressionValidationError` 字段与方法签名跨任务一致;`compress(arguments:workingDirectory:onFileAdded:)` 在 Task 3 定义、Task 4 消费一致;`CompressionController.compress(options:resolveCollision:onProgress:)` 在 Task 4 定义、Task 6 消费一致;`CreateArchiveView(defaults:onCreate:onCancel:)` 在 Task 5 定义、Task 6 消费一致;`ExtractionProgressOverlay(state:title:)` Task 6 内自洽。✓

## 计划偏移 / 待同步(与用户)

1. **进度改为「按文件计数」而非「百分比」**:实测 `-bsp1` 百分比用 `\r`/退格刷新,现有按 `\n` 的流式读接不到;而 `-bb1` 逐文件 `+ ` 行是 `\n` 分隔,可复用解压那套确定进度。故 v1 用文件计数进度(spec §后端曾写 `-bsp1` 百分比)。体验等价、实现更稳。
2. **源摘要不含总字节数**:spec §字段①写「N 项 · 合计 XX MB」;为避免在视图里同步遍历大目录(卡顿)或引入异步,v1 只显示「N 项 + 名字列表」。字节合计留待后续(可后台算)。
3. **outputDirectory 校验合一**:把「非目录」与「不可写」合并为单个 `.outputDirectoryInvalid`(ExtractOptions 分了两个)。文案已涵盖两种情形。
4. **位置校验逻辑与 ExtractOptions 有 ~8 行重复**(最近祖先可写目录):v1 就地复制并注释,未抽公共 helper(避免改动已上线的 ExtractOptions,控制范围)。可后续 DRY。

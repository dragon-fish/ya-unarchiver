# 7zip-swiftui Archiver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS SwiftUI app that browses archives like Finder (Level 1) and extracts them, wrapping a bundled `7zz` binary via subprocess.

**Architecture:** Core logic lives in a UI-free `ArchiveKit` library target (parsing, subprocess, tree building, extraction-target resolution) so it can be unit-tested with real sample archives. A separate SwiftUI executable target consumes `ArchiveKit` through an `ArchiveViewModel` state machine and renders a two-pane browser. Entry points (file association, drag-drop, menu open) all funnel into "open one archive URL → one window". Build is pure SwiftPM + a `build.sh` that assembles the `.app` bundle and ad-hoc signs it — no Xcode GUI project.

**Tech Stack:** Swift 6.2 (toolchain already installed), SwiftUI, AppKit, Swift Package Manager, XCTest, `7zz`/`7z` CLI.

## Global Constraints

- Target platform: `.macOS(.v13)` (macOS 13+). Build target triple `arm64-apple-macos13.0`.
- Build via `swift build` only; never require opening Xcode. SDK comes from `xcrun --show-sdk-path` (Command Line Tools SDK already contains SwiftUI/AppKit/QuickLook — verified).
- `ArchiveKit` target MUST NOT `import SwiftUI` or `import AppKit`. Pure Foundation only. UI-independent and unit-testable.
- App bundle name / executable: `7zip-swiftui`. Bundle identifier: `com.xiaoyujun.sevenzip-swiftui`. Swift module names use identifiers: `ArchiveKit` (library), `SevenZipApp` (executable target).
- Visual layer uses only system semantic colors (`Color.primary`, `.secondary`, `Color(nsColor:)`) and standard controls — no hardcoded hex colors. Automatic light/dark + accent following.
- The 7z binary path is injectable into `ArchiveKit` (tests use the system `/opt/homebrew/bin/7z`; the shipped app uses the bundled `7zz` in `Contents/Resources`). Never hardcode a single absolute path in logic.
- Extraction-target rule (from spec §5): single top-level dir → release as-is; otherwise wrap in `<archiveBaseName>/`; on collision prompt Cancel / Delete-then-extract / Numbered-suffix (default). `.tar.gz`/`.tar.bz2`/`.tar.xz` base-name strips two extensions.

---

## File Structure

```
Package.swift
scripts/build.sh                 # swift build + assemble .app + ad-hoc codesign
Resources/Info.plist             # app bundle Info.plist (doc types added in Task 9)
Resources/7zz                    # bundled binary (added in Task 10)
Sources/
  ArchiveKit/
    ArchiveError.swift           # typed errors
    ArchiveEntry.swift           # flat entry model
    SltParser.swift              # parse `7z l -slt` stdout → [ArchiveEntry]
    SevenZipRunner.swift         # subprocess: list() + extract()
    ArchiveTree.swift            # build tree from flat entries
    ExtractionTarget.swift       # resolveExtractionTarget()
  SevenZipApp/
    App.swift                    # @main, AppDelegate (activation), WindowGroup one-per-archive
    ArchiveViewModel.swift       # state machine loading/loaded/error/needPassword
    BrowserLayout.swift          # BrowserLayout protocol
    TwoPaneBrowserView.swift     # NavigationSplitView implementation
    ExtractionController.swift   # target resolution + collision prompt + run extract
    PasswordPromptView.swift     # password sheet
Tests/
  ArchiveKitTests/
    SltParserTests.swift
    SevenZipRunnerTests.swift
    ArchiveTreeTests.swift
    ExtractionTargetTests.swift
    TestArchives.swift           # helper: create sample archives in temp dirs
```

---

## Task 1: Project skeleton + command-line build/package pipeline

**Files:**
- Create: `Package.swift`
- Create: `Sources/SevenZipApp/App.swift`
- Create: `Sources/ArchiveKit/ArchiveError.swift` (placeholder enum so the library target compiles)
- Create: `Resources/Info.plist`
- Create: `scripts/build.sh`
- Create: `Tests/ArchiveKitTests/SltParserTests.swift` (one trivial test so `swift test` wiring works; replaced in Task 2)

**Interfaces:**
- Produces: `ArchiveError` enum (cases filled in Task 3); a runnable `.app` bundle at `.build/7zip-swiftui.app`; `scripts/build.sh` used by all later manual verification.

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "7zip-swiftui",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ArchiveKit"),
        .executableTarget(
            name: "SevenZipApp",
            dependencies: ["ArchiveKit"]
        ),
        .testTarget(
            name: "ArchiveKitTests",
            dependencies: ["ArchiveKit"]
        ),
    ]
)
```

- [ ] **Step 2: Create placeholder `Sources/ArchiveKit/ArchiveError.swift`**

```swift
import Foundation

/// Typed errors surfaced by ArchiveKit. Cases are added as tasks land.
public enum ArchiveError: Error, Equatable {
    case placeholder
}
```

- [ ] **Step 3: Create `Sources/SevenZipApp/App.swift`**

An `AppDelegate` forces regular activation so the window shows when launched from a bundle.

```swift
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SevenZipSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Text("7zip-swiftui")
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}
```

- [ ] **Step 4: Create `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>7zip-swiftui</string>
    <key>CFBundleDisplayName</key>     <string>7zip-swiftui</string>
    <key>CFBundleIdentifier</key>      <string>com.xiaoyujun.sevenzip-swiftui</string>
    <key>CFBundleExecutable</key>      <string>7zip-swiftui</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
```

- [ ] **Step 5: Create `scripts/build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="7zip-swiftui"
BIN_NAME="7zip-swiftui"          # must match CFBundleExecutable
EXEC_TARGET="SevenZipApp"        # SwiftPM product name

SDK="$(xcrun --show-sdk-path)"
echo "Building ($CONFIG)…"
swift build -c "$CONFIG" \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -target -Xswiftc arm64-apple-macos13.0

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP=".build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$EXEC_TARGET" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Bundle the 7zz binary if present (added in Task 10).
if [[ -f Resources/7zz ]]; then
    cp Resources/7zz "$APP/Contents/Resources/7zz"
    chmod +x "$APP/Contents/Resources/7zz"
fi

codesign --force --sign - "$APP"
echo "Built: $APP"
```

- [ ] **Step 6: Create trivial `Tests/ArchiveKitTests/SltParserTests.swift`**

```swift
import XCTest
@testable import ArchiveKit

final class SltParserTests: XCTestCase {
    func test_placeholder_wiring() {
        XCTAssertEqual(ArchiveError.placeholder, ArchiveError.placeholder)
    }
}
```

- [ ] **Step 7: Run tests to verify wiring**

Run: `swift test`
Expected: PASS (1 test).

- [ ] **Step 8: Build and launch the app bundle**

Run: `chmod +x scripts/build.sh && ./scripts/build.sh && open .build/7zip-swiftui.app`
Expected: A window titled area showing "7zip-swiftui" appears in the foreground with a Dock icon.

- [ ] **Step 9: Commit**

```bash
git add Package.swift scripts/build.sh Resources/Info.plist Sources Tests
git commit -m "feat: project skeleton with SwiftPM build + .app packaging"
```

---

## Task 2: ArchiveEntry model + `7z -slt` parser

**Files:**
- Create: `Sources/ArchiveKit/ArchiveEntry.swift`
- Create: `Sources/ArchiveKit/SltParser.swift`
- Replace: `Tests/ArchiveKitTests/SltParserTests.swift`

**Interfaces:**
- Produces:
  - `public struct ArchiveEntry: Equatable { public let path: String; public let size: Int64; public let packedSize: Int64; public let modified: Date?; public let isDirectory: Bool; public let isEncrypted: Bool }`
  - `public enum SltParser { public static func parse(_ output: String) -> [ArchiveEntry] }`
- Consumes: nothing.

Parsing rules (verified against real `7z l -slt` output):
- The archive-properties block appears first (starts after a `--` line); entry blocks appear after a `----------` separator line. Only parse blocks that occur **after** the `----------` line.
- Blocks are separated by blank lines. Each line is `Key = Value` (value may be empty).
- Directory detection: `Folder == "+"` (zip) OR `Attributes` contains `D` (7z). Both forms occur across formats — check both.
- Encrypted: `Encrypted == "+"`.
- `Modified` format is `yyyy-MM-dd HH:mm:ss` (may be empty for some dirs → `nil`).

- [ ] **Step 1: Write failing tests** — replace `SltParserTests.swift`

```swift
import XCTest
@testable import ArchiveKit

final class SltParserTests: XCTestCase {

    func test_parses_7z_directory_via_attributes() {
        let out = """
        --
        Path = archive.7z
        Type = 7z

        ----------
        Path = project
        Size = 0
        Packed Size = 0
        Modified = 2026-07-01 21:54:05
        Attributes = D_ drwxr-xr-x
        Encrypted = -

        Path = project/README.md
        Size = 7
        Packed Size = 20
        Modified = 2026-07-01 21:54:05
        Attributes = A_ -rw-r--r--
        Encrypted = -
        """
        let entries = SltParser.parse(out)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "project")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].path, "project/README.md")
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].size, 7)
        XCTAssertEqual(entries[1].packedSize, 20)
        XCTAssertNotNil(entries[1].modified)
    }

    func test_parses_zip_directory_via_folder_field() {
        let out = """
        --
        Path = a.zip

        ----------
        Path = f1.txt
        Folder = -
        Size = 2
        Packed Size = 2
        Encrypted = -

        Path = sub
        Folder = +
        Size = 0
        Encrypted = -
        """
        let entries = SltParser.parse(out)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(entries[0].isDirectory)   // f1.txt
        XCTAssertTrue(entries[1].isDirectory)    // sub (Folder = +)
    }

    func test_marks_encrypted_entries() {
        let out = """
        ----------
        Path = secret.txt
        Size = 2
        Encrypted = +
        Attributes = A_ -rw-r--r--
        """
        let entries = SltParser.parse(out)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isEncrypted)
    }

    func test_ignores_archive_header_block_before_separator() {
        let out = """
        --
        Path = archive.7z
        Type = 7z
        Physical Size = 269
        """
        // No entry separator / no entries → empty.
        XCTAssertTrue(SltParser.parse(out).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SltParserTests`
Expected: FAIL — `SltParser`/`ArchiveEntry` not defined.

- [ ] **Step 3: Create `Sources/ArchiveKit/ArchiveEntry.swift`**

```swift
import Foundation

public struct ArchiveEntry: Equatable {
    public let path: String
    public let size: Int64
    public let packedSize: Int64
    public let modified: Date?
    public let isDirectory: Bool
    public let isEncrypted: Bool

    public init(path: String, size: Int64, packedSize: Int64,
                modified: Date?, isDirectory: Bool, isEncrypted: Bool) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }
}
```

- [ ] **Step 4: Create `Sources/ArchiveKit/SltParser.swift`**

```swift
import Foundation

public enum SltParser {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func parse(_ output: String) -> [ArchiveEntry] {
        // Entries live after the "----------" separator. Everything before it
        // (the archive-properties block) is ignored.
        guard let sepRange = output.range(of: "\n----------\n")
                ?? output.range(of: "----------\n") else {
            return []
        }
        let body = output[sepRange.upperBound...]

        var entries: [ArchiveEntry] = []
        // Blocks separated by blank lines.
        for rawBlock in body.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in rawBlock.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let eq = line.range(of: " = ") else { continue }
                let key = String(line[line.startIndex..<eq.lowerBound])
                let value = String(line[eq.upperBound...])
                fields[key] = value
            }
            guard let path = fields["Path"], !path.isEmpty else { continue }

            let attributes = fields["Attributes"] ?? ""
            let isDir = fields["Folder"] == "+"
                || attributes.split(separator: " ").first?.contains("D") == true

            let modified = fields["Modified"].flatMap { $0.isEmpty ? nil : dateFormatter.date(from: $0) }

            entries.append(ArchiveEntry(
                path: path,
                size: Int64(fields["Size"] ?? "") ?? 0,
                packedSize: Int64(fields["Packed Size"] ?? "") ?? 0,
                modified: modified,
                isDirectory: isDir,
                isEncrypted: fields["Encrypted"] == "+"
            ))
        }
        return entries
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SltParserTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ArchiveKit/ArchiveEntry.swift Sources/ArchiveKit/SltParser.swift Tests/ArchiveKitTests/SltParserTests.swift
git commit -m "feat: ArchiveEntry model and 7z -slt parser"
```

---

## Task 3: SevenZipRunner.list — subprocess listing + typed errors

**Files:**
- Create: `Sources/ArchiveKit/SevenZipRunner.swift`
- Modify: `Sources/ArchiveKit/ArchiveError.swift` (replace placeholder with real cases)
- Create: `Tests/ArchiveKitTests/TestArchives.swift`
- Create: `Tests/ArchiveKitTests/SevenZipRunnerTests.swift`

**Interfaces:**
- Produces:
  - `public final class SevenZipRunner { public init(executableURL: URL); public func list(archive: URL, password: String?) throws -> [ArchiveEntry]; public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?) throws }` (extract implemented in Task 6; declare it now returning via `fatalError`? No — implement `list` only, add `extract` in Task 6).
  - `ArchiveError` cases: `case needsPassword`, `case wrongPassword`, `case corrupted(String)`, `case binaryNotFound`, `case executionFailed(code: Int32, message: String)`.
- Consumes: `SltParser.parse`, `ArchiveEntry` (Task 2).

Behavior (verified): `7z l -slt <archive>` lists names even for data-encrypted archives (no password needed). Header-encrypted archives print `Headers Error` and exit non-zero when no/incorrect password → map to `needsPassword`. Password passed as `-p<password>` (no space).

- [ ] **Step 1: Create test helper `Tests/ArchiveKitTests/TestArchives.swift`**

```swift
import Foundation
import XCTest

/// Creates real archives in a temp dir using the system 7z, for integration tests.
enum TestArchives {
    static let sevenZipURL = URL(fileURLWithPath: "/opt/homebrew/bin/7z")

    static func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aktests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func run7z(_ args: [String], cwd: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = sevenZipURL
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Archive whose only top-level entry is a directory `project/`.
    static func singleTopDirArchive() throws -> URL {
        let dir = try makeTempDir()
        let proj = dir.appendingPathComponent("project/src")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "hello".write(to: proj.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try run7z(["a", "-bd", "single.7z", "project"], cwd: dir)
        return dir.appendingPathComponent("single.7z")
    }

    /// Header-encrypted archive (needs password even to list).
    static func headerEncryptedArchive(password: String) throws -> URL {
        let dir = try makeTempDir()
        try "secret".write(to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        _ = try run7z(["a", "-bd", "-p\(password)", "-mhe=on", "enc.7z", "s.txt"], cwd: dir)
        return dir.appendingPathComponent("enc.7z")
    }
}
```

- [ ] **Step 2: Write failing tests `Tests/ArchiveKitTests/SevenZipRunnerTests.swift`**

```swift
import XCTest
@testable import ArchiveKit

final class SevenZipRunnerTests: XCTestCase {
    let runner = SevenZipRunner(executableURL: TestArchives.sevenZipURL)

    func test_lists_entries_of_plain_archive() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let entries = try runner.list(archive: archive, password: nil)
        let paths = entries.map(\.path)
        XCTAssertTrue(paths.contains("project"))
        XCTAssertTrue(paths.contains("project/src/a.txt"))
        XCTAssertTrue(entries.first(where: { $0.path == "project" })!.isDirectory)
    }

    func test_header_encrypted_without_password_throws_needsPassword() throws {
        let archive = try TestArchives.headerEncryptedArchive(password: "SECRET")
        XCTAssertThrowsError(try runner.list(archive: archive, password: nil)) { error in
            XCTAssertEqual(error as? ArchiveError, .needsPassword)
        }
    }

    func test_header_encrypted_with_password_lists() throws {
        let archive = try TestArchives.headerEncryptedArchive(password: "SECRET")
        let entries = try runner.list(archive: archive, password: "SECRET")
        XCTAssertTrue(entries.map(\.path).contains("s.txt"))
    }

    func test_missing_binary_throws_binaryNotFound() {
        let bad = SevenZipRunner(executableURL: URL(fileURLWithPath: "/nonexistent/7z"))
        let archive = URL(fileURLWithPath: "/tmp/whatever.7z")
        XCTAssertThrowsError(try bad.list(archive: archive, password: nil)) { error in
            XCTAssertEqual(error as? ArchiveError, .binaryNotFound)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SevenZipRunnerTests`
Expected: FAIL — `SevenZipRunner` not defined.

- [ ] **Step 4: Replace `Sources/ArchiveKit/ArchiveError.swift`**

```swift
import Foundation

public enum ArchiveError: Error, Equatable {
    case needsPassword
    case wrongPassword
    case corrupted(String)
    case binaryNotFound
    case executionFailed(code: Int32, message: String)
}
```

- [ ] **Step 5: Create `Sources/ArchiveKit/SevenZipRunner.swift`** (list only; extract added in Task 6)

```swift
import Foundation

public final class SevenZipRunner {
    private let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    struct RunResult { let code: Int32; let stdout: String; let stderr: String }

    private func run(_ arguments: [String]) throws -> RunResult {
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
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            code: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    public func list(archive: URL, password: String?) throws -> [ArchiveEntry] {
        var args = ["l", "-slt"]
        // -p with no password still disables the interactive prompt.
        args.append("-p\(password ?? "")")
        args.append(archive.path)

        let result = try run(args)
        if result.code == 0 {
            return SltParser.parse(result.stdout)
        }
        // Non-zero exit: classify.
        let combined = result.stdout + result.stderr
        if combined.contains("Headers Error")
            || combined.contains("Wrong password")
            || combined.contains("Cannot open encrypted archive") {
            throw ArchiveError.needsPassword
        }
        throw ArchiveError.corrupted(combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter SevenZipRunnerTests`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/ArchiveKit/SevenZipRunner.swift Sources/ArchiveKit/ArchiveError.swift Tests/ArchiveKitTests/TestArchives.swift Tests/ArchiveKitTests/SevenZipRunnerTests.swift
git commit -m "feat: SevenZipRunner.list with typed errors and password handling"
```

---

## Task 4: ArchiveTree — build a directory tree from flat entries

**Files:**
- Create: `Sources/ArchiveKit/ArchiveTree.swift`
- Create: `Tests/ArchiveKitTests/ArchiveTreeTests.swift`

**Interfaces:**
- Produces:
  - `public final class ArchiveNode: Identifiable { public let id: String /* full path */; public let name: String; public let isDirectory: Bool; public let entry: ArchiveEntry?; public private(set) var children: [ArchiveNode] }`
  - `public enum ArchiveTree { public static func build(from entries: [ArchiveEntry]) -> ArchiveNode /* root, name "" */ }`
- Consumes: `ArchiveEntry` (Task 2).

Rules: Some archives list a directory both as an explicit entry and implicitly via child paths. Build intermediate directory nodes on demand; attach the real `ArchiveEntry` when an explicit entry exists. `id` is the full slash path (used later by SwiftUI selection and extraction).

- [ ] **Step 1: Write failing tests `Tests/ArchiveKitTests/ArchiveTreeTests.swift`**

```swift
import XCTest
@testable import ArchiveKit

final class ArchiveTreeTests: XCTestCase {

    private func entry(_ path: String, dir: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil,
                     isDirectory: dir, isEncrypted: false)
    }

    func test_builds_nested_tree() {
        let entries = [
            entry("project", dir: true),
            entry("project/src", dir: true),
            entry("project/src/a.txt", dir: false),
            entry("project/README.md", dir: false),
        ]
        let root = ArchiveTree.build(from: entries)
        XCTAssertEqual(root.children.count, 1)
        let project = root.children[0]
        XCTAssertEqual(project.name, "project")
        XCTAssertTrue(project.isDirectory)
        XCTAssertEqual(Set(project.children.map(\.name)), ["src", "README.md"])
        let src = project.children.first { $0.name == "src" }!
        XCTAssertEqual(src.children.map(\.name), ["a.txt"])
    }

    func test_creates_implicit_intermediate_dirs() {
        // Only the leaf file is listed; "deep" and "deep/nested" are implicit.
        let entries = [entry("deep/nested/x.txt", dir: false)]
        let root = ArchiveTree.build(from: entries)
        let deep = root.children[0]
        XCTAssertEqual(deep.name, "deep")
        XCTAssertTrue(deep.isDirectory)
        XCTAssertEqual(deep.children[0].name, "nested")
        XCTAssertEqual(deep.children[0].children[0].name, "x.txt")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ArchiveTreeTests`
Expected: FAIL — `ArchiveTree`/`ArchiveNode` not defined.

- [ ] **Step 3: Create `Sources/ArchiveKit/ArchiveTree.swift`**

```swift
import Foundation

public final class ArchiveNode: Identifiable {
    public let id: String          // full path, "" for root
    public let name: String
    public let isDirectory: Bool
    public internal(set) var entry: ArchiveEntry?
    public internal(set) var children: [ArchiveNode]

    init(id: String, name: String, isDirectory: Bool, entry: ArchiveEntry?) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.entry = entry
        self.children = []
    }
}

public enum ArchiveTree {
    public static func build(from entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(id: "", name: "", isDirectory: true, entry: nil)
        var nodesByPath: [String: ArchiveNode] = ["": root]

        // Deterministic order so intermediate dirs form before leaves.
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var currentPath = ""
            var parent = root
            for (index, comp) in components.enumerated() {
                let isLast = index == components.count - 1
                let childPath = currentPath.isEmpty ? comp : currentPath + "/" + comp
                if let existing = nodesByPath[childPath] {
                    if isLast { existing.entry = entry }  // attach explicit entry
                    parent = existing
                } else {
                    let dir = isLast ? entry.isDirectory : true
                    let node = ArchiveNode(
                        id: childPath, name: comp, isDirectory: dir,
                        entry: isLast ? entry : nil
                    )
                    parent.children.append(node)
                    nodesByPath[childPath] = node
                    parent = node
                }
                currentPath = childPath
            }
        }
        return root
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ArchiveTreeTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ArchiveKit/ArchiveTree.swift Tests/ArchiveKitTests/ArchiveTreeTests.swift
git commit -m "feat: build directory tree from flat archive entries"
```

---

## Task 5: resolveExtractionTarget — extraction destination algorithm

**Files:**
- Create: `Sources/ArchiveKit/ExtractionTarget.swift`
- Create: `Tests/ArchiveKitTests/ExtractionTargetTests.swift`

**Interfaces:**
- Produces:
  - `public enum ExtractionTarget { public static func archiveBaseName(_ archive: URL) -> String; public static func hasSingleTopLevelDirectory(_ entries: [ArchiveEntry]) -> String?; public static func resolve(archive: URL, entries: [ArchiveEntry], directoryExists: (URL) -> Bool) -> URL }`
- Consumes: `ArchiveEntry` (Task 2).

Rules (spec §5):
- `archiveBaseName`: strip extension; for `.tar.gz`/`.tar.bz2`/`.tar.xz` strip both.
- `hasSingleTopLevelDirectory`: returns the dir name iff every entry's first path component equals one single name AND that top entry is a directory (an explicit dir entry, or all entries are nested beneath it). Returns `nil` otherwise.
- `resolve`: base target dir = single-top-dir name if present, else `archiveBaseName`, located in the archive's parent dir. If it exists, append ` 2`, ` 3`, … (space-separated) until free. `directoryExists` is injected for testability.

- [ ] **Step 1: Write failing tests `Tests/ArchiveKitTests/ExtractionTargetTests.swift`**

```swift
import XCTest
@testable import ArchiveKit

final class ExtractionTargetTests: XCTestCase {

    private func entry(_ path: String, dir: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil,
                     isDirectory: dir, isEncrypted: false)
    }

    func test_archiveBaseName_strips_single_and_double_extensions() {
        XCTAssertEqual(ExtractionTarget.archiveBaseName(URL(fileURLWithPath: "/d/foo.7z")), "foo")
        XCTAssertEqual(ExtractionTarget.archiveBaseName(URL(fileURLWithPath: "/d/foo.tar.gz")), "foo")
        XCTAssertEqual(ExtractionTarget.archiveBaseName(URL(fileURLWithPath: "/d/foo.tar.bz2")), "foo")
    }

    func test_single_top_level_directory_detected() {
        let entries = [
            entry("project", dir: true),
            entry("project/src", dir: true),
            entry("project/src/a.txt", dir: false),
        ]
        XCTAssertEqual(ExtractionTarget.hasSingleTopLevelDirectory(entries), "project")
    }

    func test_multiple_top_level_returns_nil() {
        let entries = [entry("f1.txt", dir: false), entry("f2.txt", dir: false)]
        XCTAssertNil(ExtractionTarget.hasSingleTopLevelDirectory(entries))
    }

    func test_single_top_level_file_returns_nil() {
        let entries = [entry("only.txt", dir: false)]
        XCTAssertNil(ExtractionTarget.hasSingleTopLevelDirectory(entries))
    }

    func test_resolve_uses_top_dir_name_when_free() {
        let entries = [entry("project", dir: true), entry("project/a.txt", dir: false)]
        let target = ExtractionTarget.resolve(
            archive: URL(fileURLWithPath: "/downloads/foo.7z"),
            entries: entries,
            directoryExists: { _ in false }
        )
        XCTAssertEqual(target.path, "/downloads/project")
    }

    func test_resolve_wraps_in_basename_when_multiple_top_level() {
        let entries = [entry("f1.txt", dir: false), entry("f2.txt", dir: false)]
        let target = ExtractionTarget.resolve(
            archive: URL(fileURLWithPath: "/downloads/foo.zip"),
            entries: entries,
            directoryExists: { _ in false }
        )
        XCTAssertEqual(target.path, "/downloads/foo")
    }

    func test_resolve_appends_numeric_suffix_on_collision() {
        let entries = [entry("f1.txt", dir: false), entry("f2.txt", dir: false)]
        let existing: Set<String> = ["/downloads/foo", "/downloads/foo 2"]
        let target = ExtractionTarget.resolve(
            archive: URL(fileURLWithPath: "/downloads/foo.zip"),
            entries: entries,
            directoryExists: { existing.contains($0.path) }
        )
        XCTAssertEqual(target.path, "/downloads/foo 3")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExtractionTargetTests`
Expected: FAIL — `ExtractionTarget` not defined.

- [ ] **Step 3: Create `Sources/ArchiveKit/ExtractionTarget.swift`**

```swift
import Foundation

public enum ExtractionTarget {

    public static func archiveBaseName(_ archive: URL) -> String {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] {
            if lower.hasSuffix(double) {
                return String(name.dropLast(double.count))
            }
        }
        return (name as NSString).deletingPathExtension
    }

    /// Returns the single top-level directory name, or nil.
    public static func hasSingleTopLevelDirectory(_ entries: [ArchiveEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var topComponents = Set<String>()
        for e in entries {
            let first = e.path.split(separator: "/").first.map(String.init) ?? e.path
            topComponents.insert(first)
        }
        guard topComponents.count == 1, let top = topComponents.first else { return nil }

        // The single top component must be a directory: either it has children
        // (some entry path contains "/") or an explicit dir entry says so.
        let hasChildren = entries.contains { $0.path.contains("/") }
        let explicitDir = entries.first { $0.path == top }?.isDirectory ?? false
        return (hasChildren || explicitDir) ? top : nil
    }

    public static func resolve(
        archive: URL,
        entries: [ArchiveEntry],
        directoryExists: (URL) -> Bool
    ) -> URL {
        let parent = archive.deletingLastPathComponent()
        let baseName = hasSingleTopLevelDirectory(entries) ?? archiveBaseName(archive)

        var candidate = parent.appendingPathComponent(baseName)
        var counter = 2
        while directoryExists(candidate) {
            candidate = parent.appendingPathComponent("\(baseName) \(counter)")
            counter += 1
        }
        return candidate
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ExtractionTargetTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ArchiveKit/ExtractionTarget.swift Tests/ArchiveKitTests/ExtractionTargetTests.swift
git commit -m "feat: extraction target resolution with single-top-dir and collision rules"
```

---

## Task 6: SevenZipRunner.extract — extract all / selected

**Files:**
- Modify: `Sources/ArchiveKit/SevenZipRunner.swift` (add `extract`)
- Modify: `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` (add extract tests)

**Interfaces:**
- Produces: `public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?) throws` on `SevenZipRunner`. `entries == nil` → extract all; otherwise only those exact paths.
- Consumes: `run(_:)`, `ArchiveError` (Task 3).

Behavior (verified): `7z x -bd -y -o<dir> [-p<pw>] <archive> [paths…]`. Wrong password exits code 2. `-o` has no space before the path. Create the destination dir first.

- [ ] **Step 1: Add failing tests to `SevenZipRunnerTests.swift`**

```swift
    func test_extract_all_writes_files() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        try runner.extract(archive: archive, entries: nil, to: dest, password: nil)
        let extracted = dest.appendingPathComponent("project/src/a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
    }

    func test_extract_wrong_password_throws() throws {
        let archive = try TestArchives.headerEncryptedArchive(password: "SECRET")
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        XCTAssertThrowsError(
            try runner.extract(archive: archive, entries: nil, to: dest, password: "WRONG")
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SevenZipRunnerTests`
Expected: FAIL — `extract` not defined.

- [ ] **Step 3: Add `extract` to `Sources/ArchiveKit/SevenZipRunner.swift`**

Add this method inside the `SevenZipRunner` class:

```swift
    public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["x", "-bd", "-y", "-o\(destination.path)", "-p\(password ?? "")", archive.path]
        if let entries {
            args.append(contentsOf: entries)
        }
        let result = try run(args)
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SevenZipRunnerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ArchiveKit/SevenZipRunner.swift Tests/ArchiveKitTests/SevenZipRunnerTests.swift
git commit -m "feat: SevenZipRunner.extract for full and selective extraction"
```

---

## Task 7: ArchiveViewModel — state machine

**Files:**
- Create: `Sources/SevenZipApp/ArchiveViewModel.swift`
- Create: `Sources/SevenZipApp/SevenZipLocator.swift`

**Interfaces:**
- Produces:
  - `enum ArchiveState { case loading; case loaded(ArchiveNode); case needsPassword; case error(String) }`
  - `@MainActor final class ArchiveViewModel: ObservableObject { let archiveURL: URL; @Published var state: ArchiveState; init(archiveURL: URL, runner: SevenZipRunner); func load(password: String?); var lastEntries: [ArchiveEntry] }`
  - `enum SevenZipLocator { static func bundledRunner() -> SevenZipRunner }` — locates `Contents/Resources/7zz`, falling back to `/opt/homebrew/bin/7z` during development.
- Consumes: `SevenZipRunner`, `ArchiveTree`, `ArchiveNode`, `ArchiveEntry`, `ArchiveError` (Tasks 2–4).

This task has no XCTest (the UI executable target isn't unit-tested; `ArchiveViewModel` depends on `@MainActor`/Combine). Verification is via build + the manual smoke test in Step 4.

- [ ] **Step 1: Create `Sources/SevenZipApp/SevenZipLocator.swift`**

```swift
import Foundation
import ArchiveKit

enum SevenZipLocator {
    static func bundledRunner() -> SevenZipRunner {
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return SevenZipRunner(executableURL: bundled)
        }
        // Development fallback when running via `swift run` (no bundle).
        return SevenZipRunner(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/7z"))
    }
}
```

- [ ] **Step 2: Create `Sources/SevenZipApp/ArchiveViewModel.swift`**

```swift
import Foundation
import ArchiveKit

enum ArchiveState {
    case loading
    case loaded(ArchiveNode)
    case needsPassword
    case error(String)
}

@MainActor
final class ArchiveViewModel: ObservableObject {
    let archiveURL: URL
    @Published var state: ArchiveState = .loading
    private(set) var lastEntries: [ArchiveEntry] = []
    private(set) var password: String?

    private let runner: SevenZipRunner

    init(archiveURL: URL, runner: SevenZipRunner = SevenZipLocator.bundledRunner()) {
        self.archiveURL = archiveURL
        self.runner = runner
    }

    func load(password: String? = nil) {
        self.password = password
        state = .loading
        let url = archiveURL
        Task.detached { [runner] in
            do {
                let entries = try runner.list(archive: url, password: password)
                let tree = ArchiveTree.build(from: entries)
                await MainActor.run {
                    self.lastEntries = entries
                    self.state = .loaded(tree)
                }
            } catch ArchiveError.needsPassword {
                await MainActor.run { self.state = .needsPassword }
            } catch {
                await MainActor.run { self.state = .error("\(error)") }
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `./scripts/build.sh`
Expected: Builds successfully (no window changes yet; wired up in Task 8).

- [ ] **Step 4: Commit**

```bash
git add Sources/SevenZipApp/ArchiveViewModel.swift Sources/SevenZipApp/SevenZipLocator.swift
git commit -m "feat: ArchiveViewModel state machine and 7zz locator"
```

---

## Task 8: Two-pane browser UI + BrowserLayout protocol

**Files:**
- Create: `Sources/SevenZipApp/BrowserLayout.swift`
- Create: `Sources/SevenZipApp/TwoPaneBrowserView.swift`
- Modify: `Sources/SevenZipApp/App.swift` (render the browser for a loaded archive)

**Interfaces:**
- Produces:
  - `protocol BrowserLayout: View { init(root: ArchiveNode, selection: Binding<ArchiveNode.ID?>) }`
  - `struct TwoPaneBrowserView: BrowserLayout` — `NavigationSplitView` with a directory `List`/`OutlineGroup` sidebar (dirs only) and a file `Table` on the right showing name / size / packed / modified.
- Consumes: `ArchiveNode` (Task 4), `ArchiveViewModel`/`ArchiveState` (Task 7).

UI-only task: no XCTest. Verified by building and launching against a real archive via a temporary hardcoded URL (removed in Task 9).

- [ ] **Step 1: Create `Sources/SevenZipApp/BrowserLayout.swift`**

```swift
import SwiftUI
import ArchiveKit

/// Abstraction so future layouts (breadcrumb, single outline) are drop-in.
protocol BrowserLayout: View {
    init(root: ArchiveNode, selection: Binding<ArchiveNode.ID?>)
}
```

- [ ] **Step 2: Create `Sources/SevenZipApp/TwoPaneBrowserView.swift`**

```swift
import SwiftUI
import ArchiveKit

struct TwoPaneBrowserView: BrowserLayout {
    let root: ArchiveNode
    @Binding var selection: ArchiveNode.ID?

    init(root: ArchiveNode, selection: Binding<ArchiveNode.ID?>) {
        self.root = root
        self._selection = selection
    }

    private var directorySubtree: [ArchiveNode] { root.children.filter(\.isDirectory) }

    private var selectedNode: ArchiveNode? {
        guard let selection else { return root }
        return Self.find(id: selection, in: root)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                OutlineGroup(directorySubtree, id: \.id, children: \.directoryChildrenOrNil) { node in
                    Label(node.name, systemImage: "folder")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            Table(selectedNode?.children ?? []) {
                TableColumn("名称") { (n: ArchiveNode) in
                    Label(n.name, systemImage: n.isDirectory ? "folder" : "doc")
                }
                TableColumn("大小") { n in Text(Self.byteString(n.entry?.size)) }
                TableColumn("压缩后") { n in Text(Self.byteString(n.entry?.packedSize)) }
                TableColumn("修改日期") { n in Text(Self.dateString(n.entry?.modified)) }
            }
        }
    }

    private static func find(id: ArchiveNode.ID, in node: ArchiveNode) -> ArchiveNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id: id, in: child) { return found }
        }
        return nil
    }

    private static func byteString(_ v: Int64?) -> String {
        guard let v else { return "—" }
        return ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    private static func dateString(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}

private extension ArchiveNode {
    /// OutlineGroup wants nil for leaves; return only directory children.
    var directoryChildrenOrNil: [ArchiveNode]? {
        let dirs = children.filter(\.isDirectory)
        return dirs.isEmpty ? nil : dirs
    }
}
```

- [ ] **Step 3: Update `Sources/SevenZipApp/App.swift` to host the browser**

Replace the `WindowGroup` body with a root view driven by the view model. Keep the `AppDelegate` unchanged. For this task, load a temporary archive path from an environment variable `SEVENZIP_DEBUG_ARCHIVE` so you can launch and see real content; Task 9 replaces this with real entry points.

```swift
import SwiftUI
import ArchiveKit

@main
struct SevenZipSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var model: ArchiveViewModel

    init() {
        let debug = ProcessInfo.processInfo.environment["SEVENZIP_DEBUG_ARCHIVE"]
        let url = URL(fileURLWithPath: debug ?? "/dev/null")
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: url))
    }

    @State private var selection: ArchiveNode.ID?

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("正在读取…")
            case .loaded(let root):
                TwoPaneBrowserView(root: root, selection: $selection)
            case .needsPassword:
                Text("需要密码（Task 9 接入密码框）").foregroundStyle(.secondary)
            case .error(let message):
                VStack { Image(systemName: "exclamationmark.triangle"); Text(message) }
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.load() }
    }
}
```

- [ ] **Step 4: Build and smoke-test against a real archive**

```bash
# Create a sample archive to look at:
cd "$(mktemp -d)"; mkdir -p project/src; echo hi > project/src/a.txt; 7z a demo.7z project >/dev/null
ARCHIVE="$PWD/demo.7z"
cd - >/dev/null
./scripts/build.sh
SEVENZIP_DEBUG_ARCHIVE="$ARCHIVE" open .build/7zip-swiftui.app
```
Expected: Window shows a sidebar with `project`/`src` and a table listing `a.txt` with size/date columns. Light/dark follows the system.

- [ ] **Step 5: Commit**

```bash
git add Sources/SevenZipApp/BrowserLayout.swift Sources/SevenZipApp/TwoPaneBrowserView.swift Sources/SevenZipApp/App.swift
git commit -m "feat: two-pane browser view behind BrowserLayout protocol"
```

---

## Task 9: Entry points, one-window-per-archive, extraction controller, prompts

**Files:**
- Create: `Sources/SevenZipApp/ExtractionController.swift`
- Create: `Sources/SevenZipApp/PasswordPromptView.swift`
- Modify: `Sources/SevenZipApp/App.swift` (document-based scene, drag-drop, open menu, toolbar buttons)
- Modify: `Resources/Info.plist` (add `CFBundleDocumentTypes`)

**Interfaces:**
- Produces:
  - `enum CollisionChoice { case cancel, deleteExisting, numbered }`
  - `@MainActor final class ExtractionController { init(runner: SevenZipRunner); func extract(archive: URL, entries: [ArchiveEntry], selectedPaths: [String]?, password: String?, resolveCollision: (URL) async -> CollisionChoice) async throws -> URL }`
  - Password sheet + toolbar wired into the archive window.
- Consumes: everything from Tasks 4–7.

UI/integration task: no XCTest. Verified via the manual scenarios in Step 6.

- [ ] **Step 1: Create `Sources/SevenZipApp/ExtractionController.swift`**

```swift
import Foundation
import ArchiveKit

enum CollisionChoice { case cancel, deleteExisting, numbered }

@MainActor
final class ExtractionController {
    private let runner: SevenZipRunner
    init(runner: SevenZipRunner) { self.runner = runner }

    /// Resolves destination per spec §5, handling collisions via the callback,
    /// then extracts. Returns the final destination directory.
    func extract(
        archive: URL,
        entries: [ArchiveEntry],
        selectedPaths: [String]?,
        password: String?,
        resolveCollision: (URL) async -> CollisionChoice
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

        let runner = self.runner
        let dest = destination
        try await Task.detached {
            try runner.extract(archive: archive, entries: selectedPaths, to: dest, password: password)
        }.value
        return destination
    }
}
```

- [ ] **Step 2: Create `Sources/SevenZipApp/PasswordPromptView.swift`**

```swift
import SwiftUI

struct PasswordPromptView: View {
    @Binding var password: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("此压缩包已加密").font(.headline)
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

- [ ] **Step 3: Rewrite `Sources/SevenZipApp/App.swift` as a document-style, one-window-per-archive scene**

Uses `WindowGroup(for: URL.self)` so each opened archive URL gets its own window; handles drag-drop, the File ▸ Open menu, and toolbar extract buttons. The password sheet and collision confirmation are presented here.

```swift
import SwiftUI
import AppKit
import ArchiveKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SevenZipSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            if let url {
                ArchiveWindow(archiveURL: url)
            } else {
                WelcomeView()
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { openArchivePanel() }
                    .keyboardShortcut("o")
            }
        }
    }

    private func openArchivePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            openWindow(value: url)
        }
    }
}

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("把压缩包拖到这里，或按 ⌘O 打开").foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 300)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openWindow(value: url)
            return true
        }
    }
}
```

- [ ] **Step 4: Create the `ArchiveWindow` view (append to `App.swift`)**

Hosts the view model, browser, password sheet, extract toolbar, and collision dialog.

```swift
struct ArchiveWindow: View {
    let archiveURL: URL
    @StateObject private var model: ArchiveViewModel
    @State private var selection: ArchiveNode.ID?
    @State private var passwordDraft = ""
    @State private var showPasswordSheet = false
    @State private var collisionContinuation: CheckedContinuation<CollisionChoice, Never>?
    @State private var collisionURL: URL?
    private let controller = ExtractionController(runner: SevenZipLocator.bundledRunner())

    init(archiveURL: URL) {
        self.archiveURL = archiveURL
        _model = StateObject(wrappedValue: ArchiveViewModel(archiveURL: archiveURL))
    }

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 460)
            .navigationTitle(archiveURL.lastPathComponent)
            .toolbar {
                ToolbarItemGroup {
                    Button { extractAll() } label: { Label("解压全部", systemImage: "arrow.down.doc") }
                    Button { extractSelected() } label: { Label("解压选中", systemImage: "arrow.down.square") }
                        .disabled(selection == nil)
                }
            }
            .onAppear { model.load() }
            .onChange(of: model.stateID) { if case .needsPassword = model.state { showPasswordSheet = true } }
            .sheet(isPresented: $showPasswordSheet) {
                PasswordPromptView(
                    password: $passwordDraft,
                    onSubmit: { showPasswordSheet = false; model.load(password: passwordDraft) },
                    onCancel: { showPasswordSheet = false }
                )
            }
            .confirmationDialog(
                "目标文件夹已存在",
                isPresented: Binding(get: { collisionURL != nil }, set: { if !$0 { finishCollision(.cancel) } })
            ) {
                Button("解压到带序号的新文件夹") { finishCollision(.numbered) }
                Button("删除原文件夹再解压", role: .destructive) { finishCollision(.deleteExisting) }
                Button("取消", role: .cancel) { finishCollision(.cancel) }
            } message: {
                Text(collisionURL?.lastPathComponent ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading: ProgressView("正在读取…")
        case .loaded(let root): TwoPaneBrowserView(root: root, selection: $selection)
        case .needsPassword: Color.clear   // sheet handles it
        case .error(let message):
            VStack { Image(systemName: "exclamationmark.triangle").font(.largeTitle); Text(message) }
                .foregroundStyle(.secondary).padding()
        }
    }

    private func extractAll() { runExtraction(selectedPaths: nil) }
    private func extractSelected() {
        guard let selection else { return }
        runExtraction(selectedPaths: [selection])
    }

    private func runExtraction(selectedPaths: [String]?) {
        Task {
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

    private func finishCollision(_ choice: CollisionChoice) {
        collisionURL = nil
        collisionContinuation?.resume(returning: choice)
        collisionContinuation = nil
    }
}
```

- [ ] **Step 5: Add `stateID` to `ArchiveViewModel` for `.onChange` and expand Info.plist**

Add to `ArchiveViewModel` (so `.onChange` has an `Equatable` to observe):

```swift
    // Add inside ArchiveViewModel:
    var stateID: Int {
        switch state {
        case .loading: return 0
        case .loaded: return 1
        case .needsPassword: return 2
        case .error: return 3
        }
    }
```

Add to `Resources/Info.plist` inside the top-level `<dict>` (declares which files the app can open via double-click / drag to Dock):

```xml
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Archive</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>public.archive</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 6: Build and run the full manual test matrix**

Run: `./scripts/build.sh && open .build/7zip-swiftui.app`
Then verify each scenario:
1. **Menu open** (⌘O) a `.7z` → window shows two-pane browser.
2. **Drag** a `.zip` onto the welcome window → new archive window opens.
3. **Double-click** a `.7z` in Finder → after choosing "always open with" or right-click Open With, it opens (may require setting default app once).
4. **Extract all** → files appear in a sibling folder named per §5 rules.
5. **Extract all again** → collision dialog offers the three choices; "numbered" makes `name 2`.
6. **Open a header-encrypted `.7z`** → password sheet appears; correct password loads the tree; wrong password re-prompts.

- [ ] **Step 7: Commit**

```bash
git add Sources/SevenZipApp Resources/Info.plist
git commit -m "feat: entry points, per-archive windows, extraction with password and collision prompts"
```

---

## Task 10: Bundle the official `7zz` binary for self-containment

**Files:**
- Create: `Resources/7zz` (downloaded binary, git-ignored or committed per size)
- Create: `scripts/fetch-7zz.sh`
- Modify: `.gitignore` (add `Resources/7zz` if not committing the binary)

**Interfaces:**
- Produces: a self-contained app whose `SevenZipLocator.bundledRunner()` resolves the in-bundle `7zz` (no dependency on Homebrew at runtime).
- Consumes: `SevenZipLocator` (Task 7), `build.sh` (Task 1, already copies `Resources/7zz` when present).

- [ ] **Step 1: Create `scripts/fetch-7zz.sh`**

Downloads the official 7-Zip macOS binary and places the `7zz` executable at `Resources/7zz`. Pin the version; verify it runs.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2409"   # 7-Zip 24.09; adjust to latest stable at implementation time
URL="https://www.7-zip.org/a/7z${VERSION}-mac.tar.xz"
TMP="$(mktemp -d)"

echo "Downloading $URL"
curl -fL "$URL" -o "$TMP/7z-mac.tar.xz"
tar -xf "$TMP/7z-mac.tar.xz" -C "$TMP"
# The archive contains a universal `7zz` at its root.
cp "$TMP/7zz" Resources/7zz
chmod +x Resources/7zz
echo "Verifying binary:"
Resources/7zz | head -3
echo "Placed Resources/7zz"
```

> Note (verify at implementation time): confirm the download URL and that the tarball's `7zz` is at its root. If the official layout differs, adjust the `cp` path. 7-Zip's macOS build is universal (arm64+x86_64).

- [ ] **Step 2: Fetch the binary**

Run: `chmod +x scripts/fetch-7zz.sh && ./scripts/fetch-7zz.sh`
Expected: `Resources/7zz` exists, is executable, and prints its 7-Zip version banner.

- [ ] **Step 3: Rebuild and confirm the bundle uses its own binary**

Run: `./scripts/build.sh && ls -la .build/7zip-swiftui.app/Contents/Resources/7zz`
Expected: `7zz` is inside the app bundle.

Verify the app no longer needs Homebrew by temporarily hiding it and opening an archive:
Run: `PATH="/usr/bin:/bin" open .build/7zip-swiftui.app`
Then open an archive via ⌘O — it should list contents (proving the bundled binary is used, since `SevenZipLocator` prefers the in-bundle path).

- [ ] **Step 4: Decide on committing the binary and update `.gitignore`**

The binary is a few MB. Default: **commit it** so the repo builds offline. If preferring not to, add to `.gitignore`:

```
Resources/7zz
```
…and document that contributors must run `scripts/fetch-7zz.sh`. Choose one; do not do both.

- [ ] **Step 5: Commit**

```bash
git add scripts/fetch-7zz.sh .gitignore
git add Resources/7zz 2>/dev/null || true   # only if committing the binary
git commit -m "feat: bundle official 7zz binary for self-contained runtime"
```

---

## Task 11: About panel showing bundled 7zz version (user-requested add-on)

**Files:**
- Modify: `Sources/ArchiveKit/SevenZipRunner.swift` (add `version()`)
- Modify: `Tests/ArchiveKitTests/SevenZipRunnerTests.swift` (add version test)
- Create: `Sources/SevenZipApp/AboutView.swift`
- Modify: `Sources/SevenZipApp/App.swift` (About scene + menu command)

**Interfaces:**
- Produces: `public func version() throws -> String` on `SevenZipRunner` — returns the 7-Zip version token (e.g. `"25.01"`), parsed from the banner's first non-empty line.
- Consumes: `run(_:)` (private, Task 3); `SevenZipLocator.bundledRunner()` (Task 7).

Verified banner formats (first NON-EMPTY line; there is a leading blank line): bundled 7zz → `7-Zip (z) 25.01 (arm64) : Copyright (c) 1999-2025 Igor Pavlov : 2025-08-03`; system p7zip → `7-Zip [64] 17.05 : Copyright ...`. Both contain a `\d+\.\d+` token. `7zz i` exits 0 and prints this banner. `version()` is TDD-tested (against the system 7z via the existing `runner`); `AboutView` is build-verified only (UI target).

- [ ] **Step 1: Write the failing test** — add to `Tests/ArchiveKitTests/SevenZipRunnerTests.swift`

```swift
    func test_version_returns_a_version_number() throws {
        let v = try runner.version()
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotNil(
            v.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression),
            "version should contain a major.minor number, got: \(v)"
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SevenZipRunnerTests`
Expected: FAIL — `value of type 'SevenZipRunner' has no member 'version'`.

- [ ] **Step 3: Add `version()` to `Sources/ArchiveKit/SevenZipRunner.swift`**

Add this method inside the `SevenZipRunner` class:

```swift
    /// Returns the 7-Zip version token (e.g. "25.01"), parsed from the banner.
    public func version() throws -> String {
        let result = try run(["i"])   // `7zz i` prints the banner + info, exits 0
        let source = result.stdout.isEmpty ? result.stderr : result.stdout
        let firstLine = source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if let range = firstLine.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) {
            return String(firstLine[range])
        }
        return firstLine.trimmingCharacters(in: .whitespaces)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SevenZipRunnerTests`
Expected: PASS (returns `"17.05"` for the system p7zip).

- [ ] **Step 5: Create `Sources/SevenZipApp/AboutView.swift`**

```swift
import SwiftUI
import AppKit
import ArchiveKit

struct AboutView: View {
    @State private var engineVersion = "…"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("7zip-swiftui").font(.title2).bold()
            Text("版本 \(appVersion)").font(.caption).foregroundStyle(.secondary)
            Divider().frame(width: 180)
            Text("压缩引擎：7-Zip \(engineVersion)")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 300)
        .task { await loadEngineVersion() }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func loadEngineVersion() async {
        let runner = SevenZipLocator.bundledRunner()
        engineVersion = await Task.detached { (try? runner.version()) ?? "不可用" }.value
    }
}
```

- [ ] **Step 6: Wire the About scene + menu command in `Sources/SevenZipApp/App.swift`**

Add a second scene after the `WindowGroup(for: URL.self)` scene (inside the `body`'s scene builder):

```swift
        Window("关于 7zip-swiftui", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
```

And in the existing `.commands { ... }`, add an app-info command group that opens it (the `@Environment(\.openWindow) private var openWindow` already exists on the App struct):

```swift
            CommandGroup(replacing: .appInfo) {
                Button("关于 7zip-swiftui") { openWindow(id: "about") }
            }
```

- [ ] **Step 7: Build + full test suite + passive launch check**

Run: `./scripts/build.sh`
Expected: builds clean.
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS (21 tests — 20 prior + the new version test).
Run: `open .build/7zip-swiftui.app` and confirm via CGWindowList it launches without crashing. (Do NOT drive the menu/About window via accessibility — per the verification policy, opening the About panel and reading its text is part of the deferred human manual pass.)

- [ ] **Step 8: Commit**

```bash
git add Sources/ArchiveKit/SevenZipRunner.swift Tests/ArchiveKitTests/SevenZipRunnerTests.swift Sources/SevenZipApp/AboutView.swift Sources/SevenZipApp/App.swift
git commit -m "feat: about panel showing bundled 7zz version"
```

---

## Self-Review

**Spec coverage:**
- §2 tech selection → Task 1 (SwiftPM/build), Task 10 (bundled 7zz). ✅
- §3 architecture layers: ArchiveKit (Tasks 2–6), Model (Tasks 2, 4), ViewModel (Task 7), two-pane UI + BrowserLayout protocol (Task 8), entry layer (Task 9). ✅
- §4 data flow (open → list → tree → render; password retry; extract) → Tasks 7, 8, 9. ✅
- §5 extraction target algorithm → Task 5 (pure logic + tests) and Task 9 (wired with collision dialog). ✅
- §6 features: entry points A/B/C → Task 9; browse Level 1 → Task 8; extract all/selected → Tasks 6, 9; encrypted password → Tasks 3, 9; semantic-color visuals → Task 8. ✅
- §7 error handling: typed fail-fast errors in ArchiveKit (Tasks 3, 6); UI graceful degradation (error state, password re-prompt) → Tasks 7–9. ✅
- §8/§9 (drag-out, QuickLook preview; Finder extension, compression) explicitly out of v1 — no tasks, correct. ✅

**Placeholder scan:** The `ArchiveError.placeholder` in Task 1 is intentional scaffolding, replaced with real cases in Task 3 Step 4. No "TBD"/"add error handling"-style gaps remain. Task 10 has one flagged "verify URL at implementation time" note — genuine external dependency, acceptable.

**Type consistency:** `SevenZipRunner(executableURL:)`, `list(archive:password:)`, `extract(archive:entries:to:password:)`, `ArchiveEntry` fields, `ArchiveNode.id`/`children`/`entry`, `ArchiveState` cases, `ExtractionTarget.resolve/hasSingleTopLevelDirectory/archiveBaseName`, `CollisionChoice` cases, `ArchiveViewModel.load(password:)`/`lastEntries`/`password`/`stateID` — names are consistent across the tasks that produce and consume them.

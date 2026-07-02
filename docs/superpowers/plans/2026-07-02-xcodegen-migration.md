# XcodeGen 迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 YA Unarchiver 从纯 SwiftPM(build.sh 组 .app)迁移为 XcodeGen 管理的标准 Xcode 项目,拿到 app target 原生 SwiftUI 预览、消除 XCTest 工具链 hack,同时保留 CLI(xcodebuild)可调试。

**Architecture:** 仓库根新增 `project.yml`(XcodeGen 声明式定义):一个 macOS app target `YAUnarchiver` 承载现有 `Sources/SevenZipApp`(源文件不挪位)并依赖本地 SwiftPM 包 `ArchiveKit`;`Package.swift` 精简为仅 `ArchiveKit` 库 + `ArchiveKitTests`。`Resources/7zz` 打包进 `Contents/Resources`,ad-hoc 签名。`Makefile` 用 `xcodegen generate` + `xcodebuild` 重写为稳定接口(`make build/run/test`)。`.xcodeproj` 生成物不入库,只提交 `project.yml`。

**Tech Stack:** XcodeGen(Homebrew)、xcodebuild、Swift 6 / SwiftUI(macOS 14)、本地 SwiftPM 包、XCTest。

## Global Constraints

- **部署目标 macOS 14**;Bundle ID `com.dragonfish.ya-unarchiver`;可执行名 `YAUnarchiver`;版本 `0.1.0` / build `1`(与现有 `Resources/Info.plist` 一致)。
- **签名 ad-hoc**:`CODE_SIGN_IDENTITY = "-"`,不启用 hardened runtime。不做 Developer ID / 公证 / DMG。
- **`.xcodeproj` 不入库**:`*.xcodeproj` 与 `xcuserdata/` 进 `.gitignore`;入库新增文件仅 `project.yml`。维持忽略 `.build/`、`Resources/7zz`、`.superpowers/`。
- **复用现有 `Resources/Info.plist`**(经 `INFOPLIST_FILE` 引用),保住 `CFBundleDocumentTypes` 文件类型关联。
- **源文件不挪位**:app 源码仍在 `Sources/SevenZipApp/`;测试仍在 `Tests/ArchiveKitTests/`。
- **构建产物固定路径**:`xcodebuild` 一律带 `-derivedDataPath .build/DerivedData`;产物 `.app` 落在 `.build/DerivedData/Build/Products/Debug/YAUnarchiver.app`。
- **提交信息** Conventional Commits + 结尾 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。

---

## File Structure

- `Package.swift` — 精简为仅 ArchiveKit 库 + 测试(修改)。
- `project.yml` — XcodeGen 工程定义(新增,入库)。
- `Makefile` — xcodegen + xcodebuild 封装(重写)。
- `.gitignore` — 忽略 `*.xcodeproj`、`xcuserdata/`(修改)。
- `README.md` — 构建说明更新(修改)。
- `scripts/build.sh` — 删除;`scripts/fetch-7zz.sh` — 保留。
- `Sources/SevenZipApp/`、`Tests/ArchiveKitTests/`、`Resources/Info.plist` — 不改内容,仅被工程引用。

---

## Task 1: 精简 Package.swift 为仅 ArchiveKit + 测试

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Consumes: 无
- Produces: 本地 SwiftPM 包对外暴露 `ArchiveKit` 库 product(供 Task 2 的 Xcode app target 依赖)。`ArchiveKitTests` 保留为包内测试 target。

- [ ] **Step 1: 改写 Package.swift**

把 `Package.swift` 整个替换为:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArchiveKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    ],
    targets: [
        .target(name: "ArchiveKit"),
        .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit"]),
    ]
)
```

- [ ] **Step 2: 验证 ArchiveKit 仍能构建**

Run: `swift build`
Expected: 只编译 `ArchiveKit`(不再有 `SevenZipApp` 可执行 target),构建成功。`Sources/SevenZipApp/` 目录存在但不被 SwiftPM 当作 target(未声明即忽略),不应报错。

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "chore(spm): slim package to ArchiveKit library + tests only

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 新增 project.yml,生成并用 xcodebuild 构建 app

安装 XcodeGen,编写工程定义,生成 `.xcodeproj`,用 xcodebuild 构建出 `.app`。

**Files:**
- Create: `project.yml`

**Interfaces:**
- Consumes: `Package.swift` 的 `ArchiveKit` 库 product(Task 1);现有 `Sources/SevenZipApp/`、`Resources/Info.plist`、`Resources/7zz`。
- Produces: 可生成的 `YAUnarchiver.xcodeproj`;scheme `YAUnarchiver`(build + run app,test action 跑 `ArchiveKitTests`)。产物路径 `.build/DerivedData/Build/Products/Debug/YAUnarchiver.app`。

- [ ] **Step 1: 安装 XcodeGen(前置)**

Run: `command -v xcodegen || brew install xcodegen`
Expected: `xcodegen` 可用(`xcodegen --version` 打印版本)。

- [ ] **Step 2: 确保 7zz 存在(资源引用前置)**

Run: `test -f Resources/7zz || ./scripts/fetch-7zz.sh`
Expected: `Resources/7zz` 存在且为可执行文件(`test -x Resources/7zz` 为真)。XcodeGen 生成工程时该资源路径必须存在。

- [ ] **Step 3: 写 project.yml**

Create `project.yml`:

```yaml
name: YAUnarchiver

options:
  bundleIdPrefix: com.dragonfish
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true

packages:
  ArchiveKit:
    path: .

targets:
  YAUnarchiver:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: Sources/SevenZipApp
      - path: Resources/7zz
        buildPhase: resources
    dependencies:
      - package: ArchiveKit
        product: ArchiveKit
    settings:
      base:
        INFOPLIST_FILE: Resources/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        PRODUCT_NAME: YAUnarchiver
        PRODUCT_BUNDLE_IDENTIFIER: com.dragonfish.ya-unarchiver
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        ENABLE_HARDENED_RUNTIME: NO
    postBuildScripts:
      - name: Ensure bundled 7zz is executable
        basedOnDependencyAnalysis: false
        script: |
          BIN="$CODESIGNING_FOLDER_PATH/Contents/Resources/7zz"
          if [ -f "$BIN" ]; then chmod +x "$BIN"; fi

  ArchiveKitTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: Tests/ArchiveKitTests
    dependencies:
      - package: ArchiveKit
        product: ArchiveKit
    settings:
      base:
        SWIFT_VERSION: "6.0"

schemes:
  YAUnarchiver:
    build:
      targets:
        YAUnarchiver: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - ArchiveKitTests
```

- [ ] **Step 4: 生成工程**

Run: `xcodegen generate`
Expected: 打印 `Created project at YAUnarchiver.xcodeproj`,无报错。

- [ ] **Step 5: 核对 scheme 名**

Run: `xcodebuild -list -project YAUnarchiver.xcodeproj`
Expected: `Schemes:` 下含 `YAUnarchiver`。若实际 scheme 名不同,以此输出为准修正后续命令(并回报)。

- [ ] **Step 6: 构建 app**

Run:
```bash
xcodebuild -project YAUnarchiver.xcodeproj -scheme YAUnarchiver \
    -configuration Debug -derivedDataPath .build/DerivedData build
```
Expected: `** BUILD SUCCEEDED **`。产物存在:`test -d .build/DerivedData/Build/Products/Debug/YAUnarchiver.app`。

若报 `@testable import ArchiveKit` 相关的 testability 错误、或 7zz 资源 / 签名相关错误,**停下并在报告中记录完整错误**(供控制器决定退路,如给 app scheme 开 `ENABLE_TESTABILITY`、或单独 ad-hoc 签 7zz)。

- [ ] **Step 7: 校验 bundle 内 7zz 已打包且可执行**

Run: `test -x .build/DerivedData/Build/Products/Debug/YAUnarchiver.app/Contents/Resources/7zz && echo OK`
Expected: 打印 `OK`(7zz 已随 bundle 拷入且有可执行位)。

- [ ] **Step 8: Commit**

```bash
git add project.yml
git commit -m "build: add XcodeGen project.yml (app target + package dep + tests)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 重写 Makefile 为 xcodegen + xcodebuild 接口

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: `project.yml`(Task 2)、scheme `YAUnarchiver`。
- Produces: `make generate/build/run/test/clean/fetch-7zz` 稳定命令。

- [ ] **Step 1: 改写 Makefile**

把 `Makefile` 整个替换为:

```makefile
# YA Unarchiver — dev tasks (XcodeGen + xcodebuild)

PROJECT := YAUnarchiver.xcodeproj
SCHEME  := YAUnarchiver
DERIVED := .build/DerivedData
APP     := $(DERIVED)/Build/Products/Debug/YAUnarchiver.app

.DEFAULT_GOAL := help
.PHONY: help generate build run test clean fetch-7zz

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

$(PROJECT): project.yml ## Generate the Xcode project from project.yml
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found — run: brew install xcodegen"; exit 1; }
	xcodegen generate

generate: $(PROJECT) ## Generate the Xcode project (regenerate if project.yml changed)

fetch-7zz: ## Re-download the bundled 7zz binary (maintenance only)
	./scripts/fetch-7zz.sh

build: generate ## Build the debug .app bundle
	@test -f Resources/7zz || ./scripts/fetch-7zz.sh
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) build

run: build ## Build, then launch the app
	open $(APP)

test: generate ## Run the unit test suite via xcodebuild (Xcode toolchain)
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED)

clean: ## Remove all build artifacts (.build, incl. DerivedData)
	rm -rf .build
```

- [ ] **Step 2: 验证 make build**

Run: `make clean && make build`
Expected: 先 `xcodegen generate`,再 `xcodebuild … build` → `** BUILD SUCCEEDED **`;`$(APP)` 存在。

- [ ] **Step 3: 验证 make test(确认无需 DEVELOPER_DIR hack)**

Run: `make test`
Expected: `xcodebuild test` 用 Xcode 工具链跑通全部 `ArchiveKitTests`,`** TEST SUCCEEDED **`,无 "no such module 'XCTest'" 之类错误。若 `@testable` testability 报错,停下并回报完整错误。

- [ ] **Step 4: 验证 make run 能定位并启动 .app**

Run: `make run`
Expected: 构建后 `open` 成功启动 `YAUnarchiver.app`(进程存在)。随后可 `osascript -e 'quit app "YAUnarchiver"'` 关闭。

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "build: rewrite Makefile around xcodegen + xcodebuild

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 清理与文档(删 build.sh、更新 .gitignore 与 README)

**Files:**
- Delete: `scripts/build.sh`
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 2/3 的工程与 Makefile。
- Produces: 干净的仓库状态(`.xcodeproj` 不入库),更新后的构建文档。

- [ ] **Step 1: 删除 build.sh**

Run: `git rm scripts/build.sh`
Expected: `scripts/build.sh` 从索引移除。`scripts/fetch-7zz.sh` 保留。

- [ ] **Step 2: 更新 .gitignore**

把 `.gitignore` 整个替换为:

```gitignore
.superpowers/
.build/
.DS_Store
.vscode/
Resources/7zz
*.xcodeproj
xcuserdata/
```

- [ ] **Step 3: 确认生成的 .xcodeproj 不被追踪**

Run: `git status --porcelain | grep -E 'xcodeproj' || echo "not tracked — good"`
Expected: 打印 `not tracked — good`(`YAUnarchiver.xcodeproj` 被忽略,不出现在待提交列表)。

- [ ] **Step 4: 更新 README 构建说明**

在 `README.md` 中:

4a. 把 "Requirements" 段的构建工具行改为(说明需要 Xcode 与 XcodeGen):

```markdown
- macOS 14 or later.
- To build: **Xcode** (full toolchain) and **XcodeGen** (`brew install xcodegen`).
  The Xcode project is generated from `project.yml` — the `.xcodeproj` itself is
  not committed.
```

4b. 把 "Build & run" 段替换为:一个 ```bash 代码块,内容为下列 5 行命令(含行尾注释)——

    brew install xcodegen   # one-time: the project is generated from project.yml
    make fetch-7zz          # download the official 7zz into Resources/
    make build              # xcodegen generate + xcodebuild → .build/DerivedData/…/YAUnarchiver.app
    make run                # build, then launch
    make test               # run the unit tests via xcodebuild

紧跟在该代码块之后加一段普通说明文字(非代码):

> Open in Xcode with `xcodegen generate && open YAUnarchiver.xcodeproj` (or `xed .`) to get live SwiftUI previews. The build uses a generated Xcode project (XcodeGen), with `ArchiveKit` as a local Swift Package dependency.

4c. 删除 README 中"pure Swift Package Manager — no Xcode project required"这句(若存在),避免与新流程矛盾。

- [ ] **Step 5: 验证 README 无残留矛盾表述**

Run: `grep -n "no Xcode project\|build.sh\|swift build" README.md || echo "clean"`
Expected: 打印 `clean`(README 不再提旧的 build.sh / swift build / no-Xcode-project)。

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: drop build.sh, ignore generated .xcodeproj, update README

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 完成后(控制器 / 用户验证)

- **消除 hack 确认**:`make test` 全绿且未用 `DEVELOPER_DIR=…`。
- **嵌套 7zz 可执行(主要风险)**:`make run` 后用真实压缩包在 GUI 里列目录 / 解压,确认 app 调用的是 bundle 内 7zz(关于面板显示 7-Zip 版本;能列出内容)。若列目录失败并回退到 `/opt/homebrew/bin/7z`,说明 bundle 内 7zz 不可执行或被签名拦截 → 按 spec 退路处理(chmod / disable-library-validation / 单独签名)。
- **预览(用户验收)**:`xcodegen generate && open YAUnarchiver.xcodeproj`(或 `xed .`),打开 `TwoPaneBrowserView.swift`,画布 Resume → 样本目录树实时渲染。
- **回归**:浏览、解压全部 / 解压选中、密码、双击打开 / 空格 QuickLook、底部路径栏 / 返回按钮 / 侧栏自动展开均正常(与迁移前一致,行为不应改变)。

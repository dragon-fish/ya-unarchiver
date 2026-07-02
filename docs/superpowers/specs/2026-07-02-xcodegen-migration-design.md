# 迁移到 XcodeGen 管理的标准 Xcode 项目 — 设计文档

日期:2026-07-02

## 背景与目标

当前工程是纯 SwiftPM:`scripts/build.sh` 用 `swift build`(CLT SDK)编译可执行档,再手工组装 `.app` bundle、ad-hoc 签名。这套能跑,但有两个硬伤:

1. **SwiftUI 预览用不了**:新版 Xcode 要求可执行 target 开 `ENABLE_DEBUG_DYLIB=YES` 才能预览,而 SwiftPM 不暴露该开关。Xcode 的错误信息明确要求"把可预览代码拆到独立 framework/target"。
2. **XCTest 工具链 hack**:CLT SDK 缺 XCTest,单测必须 `DEVELOPER_DIR=Xcode swift test`,且 build.sh(CLT)与 swift test(Xcode)混用会污染 `.build` module cache。

迁移为标准 Xcode 项目后:app target 是真 app,**原生支持预览**;测试走 Xcode 工具链,**hack 消失**;签名/资源打包交给 Xcode。用 **XcodeGen** 声明式管理(`project.yml` 入库、`.xcodeproj` 生成物不入库),避免手搓/入库 pbxproj。CLI 能力经 `xcodebuild` 保留,并包进 Makefile。

## 关键决策(已与用户确认)

- **签名**:ad-hoc 本地签名(`CODE_SIGN_IDENTITY = "-"`,Sign to Run Locally),免 Apple 账号。Developer ID + 公证 + DMG 分发是**非目标**,以后单开任务。
- **.xcodeproj 不入库**:只提交 `project.yml`;`.xcodeproj` 加入 `.gitignore`,由 `xcodegen generate` 重建(Makefile 自动处理)。
- **Package.swift 精简**:只保留 `ArchiveKit` 库 + `ArchiveKitTests`,删除 `SevenZipApp` 可执行 target;app 改由 Xcode target 承载(源文件不挪位)。

## 架构与组件

### ① `project.yml`(XcodeGen,入库)

- **本地包引用**:`packages: ArchiveKit: { path: . }`(`Package.swift` 在仓库根定义 ArchiveKit 库)。
- **app target `YAUnarchiver`**:
  - `type: application`,`platform: macOS`,部署目标 macOS 14。
  - `sources: [Sources/SevenZipApp]`(源文件保持原位,不移动)。
  - `dependencies: [{ package: ArchiveKit }]`。
  - `settings`:
    - `INFOPLIST_FILE = Resources/Info.plist`(复用现有 plist,保住 `CFBundleDocumentTypes` 文件类型关联)。
    - `PRODUCT_BUNDLE_IDENTIFIER = com.dragonfish.ya-unarchiver`。
    - `CODE_SIGN_IDENTITY = "-"`、`CODE_SIGN_STYLE = Manual`(ad-hoc);不启用 hardened runtime。
    - `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 与 Info.plist 保持一致(0.1.0 / 1)。
  - **资源**:把 `Resources/7zz` 作为 bundle 资源拷入 `Contents/Resources/7zz`(`SevenZipLocator` 靠 `Bundle.main.url(forResource:"7zz")` 定位)。以 buildPhase copy / resources 引用方式加入,标记为原样拷贝(不参与编译)。

### ② `Package.swift`(精简)

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

- 新增 `.library` product,使 Xcode app target 可依赖之。
- 删除 `SevenZipApp` 可执行 target。`Sources/SevenZipApp/` 目录保留但不再是 SPM target(SwiftPM 只构建声明的 target,忽略该目录)。

### ③ Makefile(稳定接口)

用 XcodeGen + xcodebuild 重写,对外命令不变:

- `generate`:`command -v xcodegen`,缺失则报错提示 `brew install xcodegen`;否则 `xcodegen generate`。
- `build`:确保 `Resources/7zz` 存在(缺失则先跑 `fetch-7zz`);若 `.xcodeproj` 不存在则先 `generate`;然后
  `xcodebuild -project YAUnarchiver.xcodeproj -scheme YAUnarchiver -configuration Debug -derivedDataPath .build/DerivedData build`。
- `run`:`build` 后 `open .build/DerivedData/Build/Products/Debug/YAUnarchiver.app`。
- `test`:`xcodebuild test -scheme ArchiveKit -destination 'platform=macOS' -derivedDataPath .build/DerivedData`(Xcode 工具链自带 XCTest,不再 `DEVELOPER_DIR=…`;若包 scheme 名不同,以 `xcodebuild -list` 实测为准)。
- `clean`:`rm -rf .build`(含 DerivedData)。
- `fetch-7zz`:保留(`./scripts/fetch-7zz.sh`)。

用 `-derivedDataPath .build/DerivedData` 固定产物路径,`.app` 落在 `.build/DerivedData/Build/Products/Debug/`,便于 CLI 定位与启动调试。

### ④ 清理与文档

- 删除 `scripts/build.sh`(被 xcodebuild 取代);`scripts/fetch-7zz.sh` 保留。
- `.gitignore` 增加 `*.xcodeproj`、`xcuserdata/`;维持忽略 `.build/`、`Resources/7zz`、`.superpowers/`。入库新增文件仅 `project.yml`。
- `README.md` 更新:构建需先 `brew install xcodegen`;`make build / run / test` 说明;在 Xcode 打开(`xcodegen generate` 后 open `.xcodeproj`,或 `xed .`)即得原生预览;删除"pure SwiftPM,无需 Xcode 工程"表述。

### ⑤ 预览

现有 `TwoPaneBrowserView` 的 `PreviewProvider` 在 app target 下即生效(app target 原生支持预览,无 `ENABLE_DEBUG_DYLIB` 限制)。保持现状即可;以后新预览可用 `#Preview` 宏(xcodebuild 走 Xcode 工具链,宏插件可用)。本次不改动预览代码。

## 验证策略

- `make build` 成功产出 `.app`,无错误。
- `make test` 经 xcodebuild 跑通全部 ArchiveKit 单测(确认不再需要 `DEVELOPER_DIR` hack)。
- `make run` 启动 app:两栏浏览渲染、解压正常、**能找到并调用打包进 bundle 的 7zz**(列目录成功、关于面板显示 7-Zip 版本)。
- 关键风险验证:**嵌套 7zz 在 Xcode ad-hoc 签名后仍可 exec**(用一个真实压缩包在 GUI 里列目录 / 解压确认)。
- 手动:Xcode 打开工程,`TwoPaneBrowserView` 预览画布实时渲染(由用户交互确认)。

## 已知风险与退路

- **嵌套 7zz 签名**:Xcode 对 bundle 签名会连带处理 `Resources/7zz`。ad-hoc + 不开 hardened runtime 理论上可正常执行;若被拦(library validation 等),退路:加 `com.apple.security.cs.disable-library-validation` entitlement,或在 build phase 里单独 ad-hoc 签 7zz。迁移过程中实测确认。
- **7zz 缺失导致构建失败**:`Resources/7zz` 被 gitignore,作为资源引用缺失会使 xcodebuild 报错。`make build` 在构建前确保其存在(缺则 fetch)。
- **xcodegen 未安装**:迁移前置。`make generate` 检测并提示 `brew install xcodegen`。
- **包 scheme 名不确定**:`make test` 依赖的 scheme 名以 `xcodebuild -list` 实测校正。

## 非目标(本次不做)

- Developer ID 正式签名、公证(notarization)、DMG / 发布打包。
- App 图标 asset catalog。
- 用 `#Preview` 宏全面替换现有 `PreviewProvider`。
- 为 `WelcomeView` / `AboutView` / `PasswordPromptView` 等补充预览(可后续按需)。

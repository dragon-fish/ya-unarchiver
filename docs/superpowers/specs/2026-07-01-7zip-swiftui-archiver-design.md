# 7zip-swiftui — macOS 原生解压/浏览工具 设计文档

> 状态：设计定稿（第一版）
> 日期：2026-07-01
> 工程名（临时）：`7zip-swiftui`，后续可改名

## 1. 定位与动机

macOS 缺一个"既好看、又能不整包解压就浏览压缩包内容"的解压工具（Keka 好用但不能预览内容，Bandzip 界面不佳）。本项目做一个 SwiftUI 原生 app，套壳内置 `7zz`，第一版聚焦：

- **像 Finder 一样浏览压缩包**（不整包解压即可看清结构 —— Level 1）
- **解压**（全部 / 选中 / 加密包）

架构强调**模块化**，为后续加布局、加单文件预览、加压缩功能留出干净的扩展点。

## 2. 技术选型（已定）

- **UI**：SwiftUI（原生 macOS 应用）
- **构建**：Swift Package Manager + 打包脚本，全程命令行 `swift build`，不依赖 Xcode GUI 工程。本地自用，ad-hoc 签名，不做公证/上架。
- **归档后端**：**打包官方 `7zz` 二进制进 App bundle**，子进程套壳。不自研各格式二进制 parser，不用 libarchive / 纯 Swift 库（格式覆盖不足）。
- **列目录**：`7zz l -slt <archive>`（`-slt` 提供机器友好的结构化输出），解析为条目列表。
- **解压**：`7zz x`（保留路径）到目标目录，加密包附 `-p<password>`。

### 选型依据（备忘）
- 语义颜色 + 标准控件即可自动适配亮暗/强调色，方案①"原生克制"开发最省事、体验最稳。
- `7zz` 官方提供 macOS arm64 单文件二进制，自包含、格式覆盖全（zip/7z/rar/tar/gz/xz/bz2/tar.gz…），行为与命令行一致。
- 代价：tar.gz 等流式压缩格式列目录时 `7zz` 需解压整个流，大包较慢 → UI 异步 + loading 状态处理。

## 3. 架构分层

模块化是硬约束。核心逻辑与 UI 彻底解耦。

```
┌─ 入口层 (Entry)
│    · Finder 双击文件关联（Info.plist 声明支持格式 + 处理 open-file 事件）
│    · 拖拽进窗口 / 拖到 Dock 图标
│    · 菜单 / 按钮打开（NSOpenPanel）
│    · 三种入口统一收敛为一个动作：「打开一个 archive URL」
│
├─ UI 层 (SwiftUI)
│    · 一包一窗：每个压缩包对应一个独立 Window
│    · ArchiveViewModel：状态机 loading / loaded / error / needPassword
│    · 双栏浏览视图（NavigationSplitView）：
│         左 = outline 目录树（可展开折叠）
│         右 = 选中文件夹的文件列表（名称 / 大小 / 压缩后 / 修改日期 列）
│    · 布局协议化：定义 BrowserLayout 抽象，双栏为首个实现；
│      后续加单栏面包屑 / 大纲树等布局只需新增实现，不动内核
│    · 视觉：仅用系统语义色（Color.primary/.secondary 等）+ 标准控件
│      + 毛玻璃材质，自动亮暗、自动跟随用户强调色，零适配代码
│
├─ 模型层 (Model)
│    · ArchiveEntry：path / size / packedSize / modified / isDirectory / isEncrypted / ...
│    · ArchiveTree：把 7zz 输出的扁平条目列表构建成目录树
│
└─ 后端核心 ArchiveKit（纯逻辑，无 UI，可独立单元测试）
     · list(url, password?) -> [ArchiveEntry]        // 跑 `7zz l -slt` 并解析
     · extractAll(url, to:, password?)               // `7zz x`
     · extract(entries:, from:, to:, password?)      // 解压选中项
     · resolveExtractionTarget(url, entries) -> URL   // 见 §5 解压目标算法
     · 内置 7zz 路径定位（App bundle 的 Contents/Resources/7zz）
```

**ArchiveKit 完全不 import SwiftUI**：输入 URL、输出数据或抛错，可用真实小压缩包写单元测试（TDD 友好）。后续的压缩/新建归档、单文件预览、拖出解压，都挂在这个骨架上。

## 4. 数据流

1. 入口层拿到 archive URL → 创建 document 窗口 + ArchiveViewModel。
2. ViewModel 异步调 `ArchiveKit.list(url)`。
   - 抛「需要密码」→ 状态转 `needPassword`，弹密码框，带密码重试。
   - 抛其它错误 → 状态转 `error`，展示错误横幅。
   - 成功 → 构建 ArchiveTree，状态转 `loaded`。
3. 双栏渲染：选中左树某文件夹 → 右列表展示该层内容。
4. 点「解压全部 / 解压选中」→ 调 ArchiveKit extract，进度反馈。

## 5. 解压目标算法（重点校验）

以 `~/Downloads/foo.7z` 为例，`resolveExtractionTarget` 逻辑：

1. 检查压缩包**顶级条目**（由 `list` 结果得出）：
   - **顶级有且仅有一个目录、且无其它散落的顶级文件** → 直接原样释放到同级目录，结果为 `~/Downloads/<该顶级目录名>/`（避免 `foo/foo/…` 双层嵌套）。
   - **否则**（顶级有多个条目，或顶级含文件）→ 新建以压缩包名（去扩展名）命名的文件夹兜住内容，防止"炸包"散落，结果为 `~/Downloads/foo/`。
2. 若目标文件夹**已存在**，弹窗三选一：
   - **取消**：中止解压。
   - **解压前删除原文件夹**：删除已存在目录后再解压。
   - **解压到加序号目录**（默认选中）：如 `foo 2/`、`foo 3/`，取第一个不冲突的名字。

> 注意：`.tar.gz` 等双扩展名的"去扩展名"需正确处理（`foo.tar.gz` → `foo`，而非 `foo.tar`）。

## 6. 第一版功能清单

| 类别 | 第一版包含 |
|---|---|
| 入口 | ① Finder 双击关联　② 拖拽（窗口 / Dock）　③ 菜单/按钮打开 |
| 浏览 | 双栏 Level 1：目录树 + 文件列表（名称/大小/压缩后/修改日期） |
| 解压 | ① 解压全部　② 解压选中项　⑤ 加密包弹窗输密码 |
| 视觉 | 系统语义色 + 标准控件，自动亮暗 / 强调色 |
| 格式 | 默认全开（zip/7z/rar/tar/gz/xz/bz2/tar.gz…），重点测 zip、7z、rar |

## 7. 错误处理策略

- **ArchiveKit（核心逻辑层）fail-fast**：包损坏、密码错误、`7zz` 缺失、格式不支持等，抛明确的类型化错误。
- **UI 层优雅降级**：错误横幅展示；密码错误重新弹输入框；单个文件解压失败不使整个窗口崩溃。

## 8. 紧随其后（第二批，非第一版）

- ③ 从压缩包内直接拖文件到 Finder（拖拽解压）
- ④ 单文件 QuickLook 预览（Level 2）：选中即把该文件解压到临时目录并用 QuickLook 呈现

## 9. 明确不做（第一版 YAGNI）

- D：Finder 右键扩展（Finder Sync Extension / Services）—— 会动摇"纯 SwiftPM 命令行构建"的地基，推后。
- 压缩 / 新建归档 / 加文件 / 分卷（C 大类功能）。
- 多语言、上架、公证。

## 10. 待实现时核对的技术点

- `7zz l -slt` 各格式输出字段的确切名称与格式（Path / Size / Packed Size / Modified / Attributes / Encrypted 等）。
- 官方 `7zz` macOS 二进制的获取方式与许可（7-Zip 主体 LGPL，unRAR 部分单独许可）。
- Command Line Tools 自带的 macOS SDK 是否足以构建 SwiftUI app（不足则依赖已安装的 Xcode.app SDK）。
- SwiftPM 打包 `.app` bundle（Info.plist、Resources、ad-hoc 签名）的脚本流程。

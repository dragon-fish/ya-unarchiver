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

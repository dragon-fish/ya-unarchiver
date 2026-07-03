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

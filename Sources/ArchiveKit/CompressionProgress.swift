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

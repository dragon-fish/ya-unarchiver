import Foundation
import ArchiveKit

/// Thread-safe counter for entries extracted so far. `extract` runs the 7z work on a
/// detached thread; the callback fires there, so increments must be locked.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

enum CollisionChoice { case cancel, deleteExisting, numbered }

@MainActor
final class ExtractionController {
    private let runner: SevenZipRunner
    init(runner: SevenZipRunner) { self.runner = runner }

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
}

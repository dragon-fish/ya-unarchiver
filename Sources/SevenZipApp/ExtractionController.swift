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

    /// Resolves destination per spec §5, handling collisions via the callback,
    /// then extracts. Returns the final destination directory.
    func extract(
        archive: URL,
        entries: [ArchiveEntry],
        selectedPaths: [String]?,
        password: String?,
        resolveCollision: (URL) async -> CollisionChoice,
        onProgress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
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

        let total = ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: selectedPaths)
        // Establish the overlay now that collisions are resolved and extraction is starting.
        onProgress(0, total)

        let runner = self.runner
        let dest = destination
        let singleTopDir = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        let counter = ProgressCounter()
        try await Task.detached {
            try runner.extract(archive: archive, entries: selectedPaths,
                               singleTopLevelDir: singleTopDir, to: dest, password: password,
                               onEntryExtracted: {
                let done = counter.increment()
                Task { @MainActor in onProgress(done, total) }
            })
        }.value
        return destination
    }
}

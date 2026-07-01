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

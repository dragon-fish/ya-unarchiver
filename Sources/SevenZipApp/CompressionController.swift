import Foundation
import ArchiveKit

/// Resolves output path per options, handles file-level collision, then compresses.
/// Parallels ExtractionController; reuses CollisionChoice and ProgressCounter.
@MainActor
final class CompressionController {
    private let runner: SevenZipRunner
    init(runner: SevenZipRunner) { self.runner = runner }

    func compress(
        options: CompressionOptions,
        resolveCollision: (URL) async -> CollisionChoice,
        onProgress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        var output = try options.resolveOutput()

        if fm.fileExists(atPath: output.path) {
            switch await resolveCollision(output) {
            case .cancel:
                throw CancellationError()
            case .deleteExisting:
                try fm.removeItem(at: output)
            case .numbered:
                output = CompressionOptions.numberedFile(base: output,
                                                         exists: { fm.fileExists(atPath: $0.path) })
            }
        }

        let total = CompressionProgress.totalFileCount(items: options.items,
                                                       excludeDotfiles: options.excludeDotfiles)
        onProgress(0, total)

        let runner = self.runner
        let out = output
        let args = options.arguments(output: out)
        let workdir = CompressionOptions.commonParent(of: options.items)
        let counter = ProgressCounter()
        try await Task.detached {
            try runner.compress(arguments: args, workingDirectory: workdir, onFileAdded: {
                let done = counter.increment()
                Task { @MainActor in onProgress(done, total) }
            })
        }.value
        return output
    }
}

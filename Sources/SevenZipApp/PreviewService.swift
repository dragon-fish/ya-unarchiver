import Foundation
import AppKit
import ArchiveKit

/// Extracts single files on demand to a per-window temp directory, so the UI can
/// open them with the system default app or hand them to QuickLook. One instance
/// per archive window; the temp dir is removed when the instance deinits (i.e.
/// when the window closes).
@MainActor
final class PreviewService: ObservableObject {
    let archiveURL: URL
    private let runner: SevenZipRunner
    /// Kept in sync with the unlocked archive password by the owning window.
    var password: String?

    private let tempBase: URL
    private var cache: [String: URL] = [:]   // entry path -> extracted file URL

    init(archiveURL: URL, runner: SevenZipRunner) {
        self.archiveURL = archiveURL
        self.runner = runner
        self.tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("YAUnarchiver", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Ensures `node` is extracted to the temp dir and returns its local URL.
    /// Cached after the first extraction.
    func url(for node: ArchiveNode) async throws -> URL {
        if let cached = cache[node.id] { return cached }
        let runner = self.runner
        let archiveURL = self.archiveURL
        let password = self.password
        let tempBase = self.tempBase
        let entryPath = node.id
        let fileURL = try await Task.detached {
            try runner.extract(archive: archiveURL, entries: [entryPath], to: tempBase, password: password)
            return PreviewPaths.fileURL(tempBase: tempBase, entryPath: entryPath)
        }.value
        cache[node.id] = fileURL
        return fileURL
    }

    /// Extracts (if needed) and opens the file with the system default app.
    func open(_ node: ArchiveNode) async {
        guard let url = try? await url(for: node) else { return }
        NSWorkspace.shared.open(url)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempBase)
    }
}

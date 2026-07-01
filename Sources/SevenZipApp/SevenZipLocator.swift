import Foundation
import ArchiveKit

enum SevenZipLocator {
    static func bundledRunner() -> SevenZipRunner {
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return SevenZipRunner(executableURL: bundled)
        }
        // Development fallback when running via `swift run` (no bundle).
        return SevenZipRunner(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/7z"))
    }
}

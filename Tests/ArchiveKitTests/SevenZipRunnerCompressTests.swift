import XCTest
@testable import ArchiveKit

final class SevenZipRunnerCompressTests: XCTestCase {
    let runner = SevenZipRunner(executableURL: TestArchives.sevenZipURL)

    func test_isAddedLine() {
        XCTAssertTrue(SevenZipRunner.isAddedLine("+ src/a.txt"))
        XCTAssertFalse(SevenZipRunner.isAddedLine("Everything is Ok"))
        XCTAssertFalse(SevenZipRunner.isAddedLine("Files read from disk: 3"))
    }

    /// Compress a folder to 7z, then list it back and assert entries + relative paths.
    func test_compress_7z_writes_expected_entries() throws {
        // Proves -bb1 streams per-added-file lines through a Pipe (non-TTY), so the callback fires.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let dir = try TestArchives.makeTempDir()
        let src = dir.appendingPathComponent("src/sub")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hi".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "d".write(to: dir.appendingPathComponent("src/.DS_Store"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out.7z")

        let counter = Counter()
        try runner.compress(
            arguments: ["a", "-t7z", "-mx=1", "-bb1", "-y", "-xr!.*", out.path, "src"],
            workingDirectory: dir,
            onFileAdded: { counter.bump() })

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let paths = try runner.list(archive: out, password: nil).map(\.path)
        XCTAssertTrue(paths.contains("src/sub/a.txt"))
        XCTAssertFalse(paths.contains("src/.DS_Store"))   // dotfile excluded
        XCTAssertEqual(counter.count, 1)                  // one regular file added
    }

    /// Header-encrypted 7z needs a password even to list.
    func test_compress_7z_header_encrypted() throws {
        let dir = try TestArchives.makeTempDir()
        try "secret".write(to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("enc.7z")
        try runner.compress(
            arguments: ["a", "-t7z", "-mx=1", "-bb1", "-y", "-pPW", "-mhe=on", out.path, "s.txt"],
            workingDirectory: dir, onFileAdded: nil)
        XCTAssertThrowsError(try runner.list(archive: out, password: nil)) { e in
            XCTAssertEqual(e as? ArchiveError, .needsPassword)
        }
        XCTAssertTrue(try runner.list(archive: out, password: "PW").map(\.path).contains("s.txt"))
    }
}

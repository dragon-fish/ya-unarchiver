import XCTest
@testable import ArchiveKit

final class SevenZipRunnerTests: XCTestCase {
    let runner = SevenZipRunner(executableURL: TestArchives.sevenZipURL)

    func test_lists_entries_of_plain_archive() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let entries = try runner.list(archive: archive, password: nil)
        let paths = entries.map(\.path)
        XCTAssertTrue(paths.contains("project"))
        XCTAssertTrue(paths.contains("project/src/a.txt"))
        XCTAssertTrue(entries.first(where: { $0.path == "project" })!.isDirectory)
    }

    func test_header_encrypted_without_password_throws_needsPassword() throws {
        let archive = try TestArchives.headerEncryptedArchive(password: "SECRET")
        XCTAssertThrowsError(try runner.list(archive: archive, password: nil)) { error in
            XCTAssertEqual(error as? ArchiveError, .needsPassword)
        }
    }

    func test_header_encrypted_with_password_lists() throws {
        let archive = try TestArchives.headerEncryptedArchive(password: "SECRET")
        let entries = try runner.list(archive: archive, password: "SECRET")
        XCTAssertTrue(entries.map(\.path).contains("s.txt"))
    }

    func test_missing_binary_throws_binaryNotFound() {
        let bad = SevenZipRunner(executableURL: URL(fileURLWithPath: "/nonexistent/7z"))
        let archive = URL(fileURLWithPath: "/tmp/whatever.7z")
        XCTAssertThrowsError(try bad.list(archive: archive, password: nil)) { error in
            XCTAssertEqual(error as? ArchiveError, .binaryNotFound)
        }
    }

    func test_extract_all_writes_files() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        try runner.extract(archive: archive, entries: nil, to: dest, password: nil)
        let extracted = dest.appendingPathComponent("project/src/a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
    }

    func test_extract_selected_only_writes_chosen_entries() throws {
        let archive = try TestArchives.twoFileArchive()
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        try runner.extract(archive: archive, entries: ["f1.txt"], to: dest, password: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f1.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f2.txt").path))
    }

    func test_extract_wrong_password_throws() throws {
        let archive = try TestArchives.headerEncryptedArchive(password: "SECRET")
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        XCTAssertThrowsError(
            try runner.extract(archive: archive, entries: nil, to: dest, password: "WRONG")
        )
    }

    func test_extract_single_top_dir_does_not_double_nest() throws {
        let archive = try TestArchives.singleTopDirArchive()          // entries under project/
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project")
        try runner.extract(archive: archive, entries: nil, singleTopLevelDir: "project",
                           to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: finalFolder.appendingPathComponent("project").path),
                       "must not double-nest as project/project")
    }

    func test_extract_single_top_dir_into_numbered_folder() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project 2")
        try runner.extract(archive: archive, entries: nil, singleTopLevelDir: "project",
                           to: finalFolder, password: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
    }

    func test_extract_wrap_case_places_entries_under_final_folder() throws {
        let archive = try TestArchives.twoFileArchive()
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("bundle")
        try runner.extract(archive: archive, entries: nil, singleTopLevelDir: nil,
                           to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("f1.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("f2.txt").path))
    }

    func test_extract_selected_subset_under_single_top_dir_strips_prefix() throws {
        // b1 regression: selecting a single entry inside a single-top-dir archive
        // must land at finalFolder/<relative-to-topdir>, NOT finalFolder/project/…
        let archive = try TestArchives.singleTopDirArchive()          // project/src/a.txt
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project")
        try runner.extract(archive: archive, entries: ["project/src/a.txt"],
                           singleTopLevelDir: "project", to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: finalFolder.appendingPathComponent("project").path),
                       "selected-subset extraction must not double-nest as project/project")
    }

    func test_version_returns_a_version_number() throws {
        let v = try runner.version()
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotNil(
            v.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression),
            "version should contain a major.minor number, got: \(v)"
        )
    }

    func test_isEntryLine_matches_only_entry_lines() {
        XCTAssertTrue(SevenZipRunner.isEntryLine("- big/sub/f001.bin"))
        XCTAssertTrue(SevenZipRunner.isEntryLine("- big/"))
        XCTAssertFalse(SevenZipRunner.isEntryLine("Everything is Ok"))
        XCTAssertFalse(SevenZipRunner.isEntryLine("Extracting archive: /tmp/a.7z"))
        XCTAssertFalse(SevenZipRunner.isEntryLine("--"))
        XCTAssertFalse(SevenZipRunner.isEntryLine(""))
    }

    func test_extract_reports_per_entry_progress() throws {
        // Proves -bb1 streams per-entry lines through a Pipe (non-TTY), so the callback fires.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let archive = try TestArchives.twoFileArchive()     // f1.txt, f2.txt
        let dest = try TestArchives.makeTempDir().appendingPathComponent("out")
        let counter = Counter()
        try runner.extract(archive: archive, entries: nil, to: dest, password: nil,
                           onEntryExtracted: { counter.bump() })
        XCTAssertGreaterThanOrEqual(counter.count, 2, "should report at least one line per extracted file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f2.txt").path))
    }
}

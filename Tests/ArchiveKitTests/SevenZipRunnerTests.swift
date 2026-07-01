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

    func test_extractAll_single_top_dir_does_not_double_nest() throws {
        let archive = try TestArchives.singleTopDirArchive()          // entries under project/
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project")
        try runner.extractAll(archive: archive, singleTopLevelDir: "project", to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: finalFolder.appendingPathComponent("project").path),
                       "must not double-nest as project/project")
    }

    func test_extractAll_single_top_dir_into_numbered_folder() throws {
        let archive = try TestArchives.singleTopDirArchive()
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("project 2")
        try runner.extractAll(archive: archive, singleTopLevelDir: "project", to: finalFolder, password: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent("src/a.txt").path))
    }

    func test_extractAll_wrap_case_places_entries_under_final_folder() throws {
        let archive = try TestArchives.twoFileArchive()
        let finalFolder = try TestArchives.makeTempDir().appendingPathComponent("bundle")
        try runner.extractAll(archive: archive, singleTopLevelDir: nil, to: finalFolder, password: nil)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("f1.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: finalFolder.appendingPathComponent("f2.txt").path))
    }

    func test_version_returns_a_version_number() throws {
        let v = try runner.version()
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotNil(
            v.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression),
            "version should contain a major.minor number, got: \(v)"
        )
    }
}

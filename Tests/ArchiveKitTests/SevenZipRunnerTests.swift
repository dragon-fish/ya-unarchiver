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
}

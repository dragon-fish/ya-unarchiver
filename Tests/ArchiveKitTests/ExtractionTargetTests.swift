import XCTest
@testable import ArchiveKit

final class ExtractionTargetTests: XCTestCase {

    private func entry(_ path: String, dir: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil,
                     isDirectory: dir, isEncrypted: false)
    }

    func test_archiveBaseName_strips_single_and_double_extensions() {
        XCTAssertEqual(ExtractionTarget.archiveBaseName(URL(fileURLWithPath: "/d/foo.7z")), "foo")
        XCTAssertEqual(ExtractionTarget.archiveBaseName(URL(fileURLWithPath: "/d/foo.tar.gz")), "foo")
        XCTAssertEqual(ExtractionTarget.archiveBaseName(URL(fileURLWithPath: "/d/foo.tar.bz2")), "foo")
    }

    func test_single_top_level_directory_detected() {
        let entries = [
            entry("project", dir: true),
            entry("project/src", dir: true),
            entry("project/src/a.txt", dir: false),
        ]
        XCTAssertEqual(ExtractionTarget.hasSingleTopLevelDirectory(entries), "project")
    }

    func test_multiple_top_level_returns_nil() {
        let entries = [entry("f1.txt", dir: false), entry("f2.txt", dir: false)]
        XCTAssertNil(ExtractionTarget.hasSingleTopLevelDirectory(entries))
    }

    func test_single_top_level_file_returns_nil() {
        let entries = [entry("only.txt", dir: false)]
        XCTAssertNil(ExtractionTarget.hasSingleTopLevelDirectory(entries))
    }

    func test_resolve_uses_top_dir_name_when_free() {
        let entries = [entry("project", dir: true), entry("project/a.txt", dir: false)]
        let target = ExtractionTarget.resolve(
            archive: URL(fileURLWithPath: "/downloads/foo.7z"),
            entries: entries,
            directoryExists: { _ in false }
        )
        XCTAssertEqual(target.path, "/downloads/project")
    }

    func test_resolve_wraps_in_basename_when_multiple_top_level() {
        let entries = [entry("f1.txt", dir: false), entry("f2.txt", dir: false)]
        let target = ExtractionTarget.resolve(
            archive: URL(fileURLWithPath: "/downloads/foo.zip"),
            entries: entries,
            directoryExists: { _ in false }
        )
        XCTAssertEqual(target.path, "/downloads/foo")
    }

    func test_resolve_appends_numeric_suffix_on_collision() {
        let entries = [entry("f1.txt", dir: false), entry("f2.txt", dir: false)]
        let existing: Set<String> = ["/downloads/foo", "/downloads/foo 2"]
        let target = ExtractionTarget.resolve(
            archive: URL(fileURLWithPath: "/downloads/foo.zip"),
            entries: entries,
            directoryExists: { existing.contains($0.path) }
        )
        XCTAssertEqual(target.path, "/downloads/foo 3")
    }
}

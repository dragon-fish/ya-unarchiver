import XCTest
@testable import ArchiveKit

final class ExtractionProgressTests: XCTestCase {
    private func entry(_ path: String, dir: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil, isDirectory: dir, isEncrypted: false)
    }

    func test_total_all_entries_when_no_selection() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("b.txt")]
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: nil), 3)
    }

    func test_total_selected_single_file() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("a/y.txt")]
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: ["a/x.txt"]), 1)
    }

    func test_total_selected_directory_includes_subtree() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("a/sub/y.txt"), entry("b.txt")]
        // a + a/x.txt + a/sub/y.txt = 3
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: ["a"]), 3)
    }

    func test_total_prefix_does_not_match_sibling() {
        let entries = [entry("a", dir: true), entry("a/x.txt"), entry("ab", dir: true), entry("ab/y.txt")]
        // selecting "a" must count a + a/x.txt only, NOT ab or ab/y.txt
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: ["a"]), 2)
    }

    func test_total_empty_selection_is_zero() {
        let entries = [entry("x.txt")]
        XCTAssertEqual(ExtractionProgress.totalEntryCount(entries: entries, selectedPaths: []), 0)
    }
}

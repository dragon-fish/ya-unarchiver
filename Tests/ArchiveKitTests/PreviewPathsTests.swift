import XCTest
@testable import ArchiveKit

final class PreviewPathsTests: XCTestCase {
    func test_fileURL_nested_entry() {
        let base = URL(fileURLWithPath: "/tmp/ya")
        XCTAssertEqual(
            PreviewPaths.fileURL(tempBase: base, entryPath: "a/b/c.png").path,
            "/tmp/ya/a/b/c.png"
        )
    }

    func test_fileURL_top_level_entry() {
        let base = URL(fileURLWithPath: "/tmp/ya")
        XCTAssertEqual(
            PreviewPaths.fileURL(tempBase: base, entryPath: "c.png").path,
            "/tmp/ya/c.png"
        )
    }

    func test_fileURL_entry_with_spaces() {
        let base = URL(fileURLWithPath: "/tmp/ya")
        XCTAssertEqual(
            PreviewPaths.fileURL(tempBase: base, entryPath: "my dir/my file.txt").path,
            "/tmp/ya/my dir/my file.txt"
        )
    }
}

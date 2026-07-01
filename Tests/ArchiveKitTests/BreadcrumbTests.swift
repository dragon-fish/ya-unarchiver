import XCTest
@testable import ArchiveKit

final class BreadcrumbTests: XCTestCase {
    func test_segments_nested_path() {
        XCTAssertEqual(
            Breadcrumb.segments(forPath: "a/b/c"),
            [BreadcrumbSegment(name: "a", id: "a"),
             BreadcrumbSegment(name: "b", id: "a/b"),
             BreadcrumbSegment(name: "c", id: "a/b/c")]
        )
    }

    func test_segments_single_component() {
        XCTAssertEqual(
            Breadcrumb.segments(forPath: "only"),
            [BreadcrumbSegment(name: "only", id: "only")]
        )
    }

    func test_segments_empty_path_is_root_and_returns_empty() {
        XCTAssertEqual(Breadcrumb.segments(forPath: ""), [])
    }
}

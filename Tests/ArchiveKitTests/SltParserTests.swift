import XCTest
@testable import ArchiveKit

final class SltParserTests: XCTestCase {
    func test_placeholder_wiring() {
        XCTAssertEqual(ArchiveError.placeholder, ArchiveError.placeholder)
    }
}

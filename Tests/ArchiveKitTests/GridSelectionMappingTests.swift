import XCTest
@testable import ArchiveKit

final class GridSelectionMappingTests: XCTestCase {
    // Top-level children in a known, deterministic order (ArchiveTree sorts entries by path).
    private func sampleNodes() -> [ArchiveNode] {
        let entries: [ArchiveEntry] = [
            .init(path: "a.txt", size: 1, packedSize: 1, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "b.txt", size: 1, packedSize: 1, modified: nil, isDirectory: false, isEncrypted: false),
            .init(path: "c.txt", size: 1, packedSize: 1, modified: nil, isDirectory: false, isEncrypted: false),
        ]
        return ArchiveTree.build(from: entries).children
    }

    func testIdsForRowsBasic() {
        let nodes = sampleNodes()
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [0], in: nodes), [nodes[0].id])
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [0, 2], in: nodes), [nodes[0].id, nodes[2].id])
    }

    func testIdsForRowsEmpty() {
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [], in: sampleNodes()), [])
    }

    func testIdsForRowsOutOfRangeIgnored() {
        let nodes = sampleNodes()
        XCTAssertEqual(GridSelectionMapping.ids(forRows: [-1, 1, 99], in: nodes), [nodes[1].id])
    }

    func testRowsForIdsSortedAscending() {
        let nodes = sampleNodes()
        let ids: Set<ArchiveNode.ID> = [nodes[2].id, nodes[0].id]
        XCTAssertEqual(GridSelectionMapping.rows(forIDs: ids, in: nodes), [0, 2])
    }

    func testRowsForIdsUnknownDropped() {
        let nodes = sampleNodes()
        XCTAssertEqual(GridSelectionMapping.rows(forIDs: ["does/not/exist"], in: nodes), [])
    }

    func testRoundTrip() {
        let nodes = sampleNodes()
        let rows = [0, 2]
        let ids = GridSelectionMapping.ids(forRows: rows, in: nodes)
        XCTAssertEqual(GridSelectionMapping.rows(forIDs: ids, in: nodes), rows)
    }
}

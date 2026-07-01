import XCTest
@testable import ArchiveKit

final class ArchiveTreeTests: XCTestCase {

    private func entry(_ path: String, dir: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil,
                     isDirectory: dir, isEncrypted: false)
    }

    func test_builds_nested_tree() {
        let entries = [
            entry("project", dir: true),
            entry("project/src", dir: true),
            entry("project/src/a.txt", dir: false),
            entry("project/README.md", dir: false),
        ]
        let root = ArchiveTree.build(from: entries)
        XCTAssertEqual(root.children.count, 1)
        let project = root.children[0]
        XCTAssertEqual(project.name, "project")
        XCTAssertTrue(project.isDirectory)
        XCTAssertEqual(Set(project.children.map(\.name)), ["src", "README.md"])
        let src = project.children.first { $0.name == "src" }!
        XCTAssertEqual(src.children.map(\.name), ["a.txt"])
    }

    func test_creates_implicit_intermediate_dirs() {
        // Only the leaf file is listed; "deep" and "deep/nested" are implicit.
        let entries = [entry("deep/nested/x.txt", dir: false)]
        let root = ArchiveTree.build(from: entries)
        let deep = root.children[0]
        XCTAssertEqual(deep.name, "deep")
        XCTAssertTrue(deep.isDirectory)
        XCTAssertEqual(deep.children[0].name, "nested")
        XCTAssertEqual(deep.children[0].children[0].name, "x.txt")
    }
}

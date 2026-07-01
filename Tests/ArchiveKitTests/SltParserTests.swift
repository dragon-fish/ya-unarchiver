import XCTest
@testable import ArchiveKit

final class SltParserTests: XCTestCase {

    func test_parses_7z_directory_via_attributes() {
        let out = """
        --
        Path = archive.7z
        Type = 7z

        ----------
        Path = project
        Size = 0
        Packed Size = 0
        Modified = 2026-07-01 21:54:05
        Attributes = D_ drwxr-xr-x
        Encrypted = -

        Path = project/README.md
        Size = 7
        Packed Size = 20
        Modified = 2026-07-01 21:54:05
        Attributes = A_ -rw-r--r--
        Encrypted = -
        """
        let entries = SltParser.parse(out)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "project")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].path, "project/README.md")
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].size, 7)
        XCTAssertEqual(entries[1].packedSize, 20)
        XCTAssertNotNil(entries[1].modified)
    }

    func test_parses_zip_directory_via_folder_field() {
        let out = """
        --
        Path = a.zip

        ----------
        Path = f1.txt
        Folder = -
        Size = 2
        Packed Size = 2
        Encrypted = -

        Path = sub
        Folder = +
        Size = 0
        Encrypted = -
        """
        let entries = SltParser.parse(out)
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(entries[0].isDirectory)   // f1.txt
        XCTAssertTrue(entries[1].isDirectory)    // sub (Folder = +)
    }

    func test_marks_encrypted_entries() {
        let out = """
        ----------
        Path = secret.txt
        Size = 2
        Encrypted = +
        Attributes = A_ -rw-r--r--
        """
        let entries = SltParser.parse(out)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isEncrypted)
    }

    func test_ignores_archive_header_block_before_separator() {
        let out = """
        --
        Path = archive.7z
        Type = 7z
        Physical Size = 269
        """
        // No entry separator / no entries → empty.
        XCTAssertTrue(SltParser.parse(out).isEmpty)
    }
}

import XCTest
@testable import ArchiveKit

final class ExtractOptionsTests: XCTestCase {

    /// A real, writable temp directory to use as a valid `location`.
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("extractopts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func options(location: URL, subEnabled: Bool = true, subName: String = "out",
                         strip: Bool = true, overwrite: OverwritePolicy = .ask,
                         password: String = "") -> ExtractOptions {
        ExtractOptions(location: location, subfolderEnabled: subEnabled, subfolderName: subName,
                       stripSingleTopDir: strip, overwriteMode: overwrite, password: password)
    }

    func test_validate_passes_for_writable_dir_and_clean_name() throws {
        let dir = try tempDir()
        XCTAssertEqual(options(location: dir).validate(), [])
    }

    func test_validate_flags_nonexistent_location() {
        let missing = URL(fileURLWithPath: "/no/such/dir-\(UUID().uuidString)")
        XCTAssertEqual(options(location: missing).validate(), [.locationNotADirectory])
    }

    func test_validate_flags_file_location_as_not_a_directory() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(options(location: file).validate(), [.locationNotADirectory])
    }

    func test_validate_rejects_subfolder_names_with_illegal_chars() throws {
        let dir = try tempDir()
        for bad in ["a/b", "a:b", ".", "..", "../x"] {
            XCTAssertEqual(options(location: dir, subName: bad).validate(), [.invalidSubfolderName],
                           "expected \(bad) to be invalid")
        }
    }

    func test_validate_trims_whitespace_then_accepts() throws {
        let dir = try tempDir()
        XCTAssertEqual(options(location: dir, subName: "  keep  ").validate(), [])
    }

    func test_validate_empty_subfolder_name_is_not_an_error() throws {
        let dir = try tempDir()
        // Empty name = "no subfolder / dump" — a warning case, not a validation error.
        XCTAssertEqual(options(location: dir, subName: "   ").validate(), [])
    }

    func test_normalizeLocation_expands_tilde_and_standardizes() {
        let url = ExtractOptions.normalizeLocation("~/Downloads/../Downloads")
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertFalse(url.path.contains(".."))
        XCTAssertTrue(url.path.hasSuffix("/Downloads"))
    }
}

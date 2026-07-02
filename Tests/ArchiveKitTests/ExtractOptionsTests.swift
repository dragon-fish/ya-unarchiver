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

    private func entry(_ path: String, dir: Bool) -> ArchiveEntry {
        ArchiveEntry(path: path, size: 0, packedSize: 0, modified: nil,
                     isDirectory: dir, isEncrypted: false)
    }

    func test_resolve_subfolder_enabled_appends_name_and_strips() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "proj", strip: true)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertEqual(r.finalFolder, dir.appendingPathComponent("proj"))
        XCTAssertFalse(r.dumpIntoExisting)
        XCTAssertEqual(r.stripTopDir, "proj")
    }

    func test_resolve_strip_off_keeps_topdir() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "proj", strip: false)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertNil(r.stripTopDir)
    }

    func test_resolve_no_singletopdir_yields_nil_strip() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "proj", strip: true)
            .resolveDestination(singleTopLevelDir: nil)
        XCTAssertNil(r.stripTopDir)
    }

    func test_resolve_dump_when_subfolder_disabled() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subEnabled: false, subName: "proj", strip: true)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertEqual(r.finalFolder, dir)
        XCTAssertTrue(r.dumpIntoExisting)
        XCTAssertNil(r.stripTopDir)
    }

    func test_resolve_dump_when_subfolder_name_empty() throws {
        let dir = try tempDir()
        let r = try options(location: dir, subName: "   ", strip: true)
            .resolveDestination(singleTopLevelDir: "proj")
        XCTAssertEqual(r.finalFolder, dir)
        XCTAssertTrue(r.dumpIntoExisting)
    }

    func test_resolve_throws_on_invalid() throws {
        let missing = URL(fileURLWithPath: "/no/such/dir-\(UUID().uuidString)")
        XCTAssertThrowsError(try options(location: missing)
            .resolveDestination(singleTopLevelDir: nil)) { error in
            guard case ArchiveError.invalidDestination = error else {
                return XCTFail("expected invalidDestination, got \(error)")
            }
        }
    }

    func test_defaults_match_legacy_target_single_topdir() throws {
        let parent = try tempDir()
        let archive = parent.appendingPathComponent("foo.7z")
        let entries = [entry("proj", dir: true), entry("proj/a.txt", dir: false)]
        let opts = ExtractOptions.defaults(archive: archive, entries: entries, password: "")
        let top = ExtractionTarget.hasSingleTopLevelDirectory(entries)
        let r = try opts.resolveDestination(singleTopLevelDir: top)
        // Legacy: firstChoice = parent/(topdir ?? baseName) = parent/proj ; strip = topdir
        XCTAssertEqual(r.finalFolder, parent.appendingPathComponent("proj"))
        XCTAssertEqual(r.stripTopDir, "proj")
    }

    func test_defaults_match_legacy_target_no_topdir() throws {
        let parent = try tempDir()
        let archive = parent.appendingPathComponent("foo.7z")
        let entries = [entry("a.txt", dir: false), entry("b.txt", dir: false)]
        let opts = ExtractOptions.defaults(archive: archive, entries: entries, password: "")
        let r = try opts.resolveDestination(singleTopLevelDir: nil)
        XCTAssertEqual(r.finalFolder, parent.appendingPathComponent("foo"))
        XCTAssertNil(r.stripTopDir)
    }

    func test_numbered_appends_suffix_until_free() {
        var existing: Set<String> = ["/d/proj", "/d/proj 2"]
        let out = ExtractionTarget.numbered(base: URL(fileURLWithPath: "/d/proj"),
                                            directoryExists: { existing.contains($0.path) })
        XCTAssertEqual(out, URL(fileURLWithPath: "/d/proj 3"))
        _ = existing // silence unused-mutability
    }

    func test_numbered_returns_base_when_free() {
        let out = ExtractionTarget.numbered(base: URL(fileURLWithPath: "/d/proj"),
                                            directoryExists: { _ in false })
        XCTAssertEqual(out, URL(fileURLWithPath: "/d/proj"))
    }
}

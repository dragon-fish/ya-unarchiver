import XCTest
@testable import ArchiveKit

final class CompressionOptionsTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func opts(items: [URL], outDir: URL, name: String = "Archive",
                      format: ArchiveFormat = .sevenZip, level: CompressionLevel = .normal,
                      password: String = "", encryptHeader: Bool = true,
                      excludeDotfiles: Bool = true) -> CompressionOptions {
        CompressionOptions(items: items, outputDirectory: outDir, archiveName: name,
                           format: format, level: level, password: password,
                           encryptHeader: encryptHeader, excludeDotfiles: excludeDotfiles)
    }

    func test_format_extension_and_header_support() {
        XCTAssertEqual(ArchiveFormat.sevenZip.fileExtension, "7z")
        XCTAssertEqual(ArchiveFormat.zip.fileExtension, "zip")
        XCTAssertTrue(ArchiveFormat.sevenZip.supportsHeaderEncryption)
        XCTAssertFalse(ArchiveFormat.zip.supportsHeaderEncryption)
    }

    func test_validate_passes_for_items_writable_dir_clean_name() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt")
        try "x".write(to: item, atomically: true, encoding: .utf8)
        XCTAssertEqual(opts(items: [item], outDir: dir, name: "out").validate(), [])
    }

    func test_validate_flags_empty_items() throws {
        let dir = try tempDir()
        XCTAssertEqual(opts(items: [], outDir: dir, name: "out").validate(), [.noItems])
    }

    func test_validate_allows_nonexistent_output_dir_under_writable_parent() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        let newOut = dir.appendingPathComponent("new-\(UUID().uuidString)")
        XCTAssertEqual(opts(items: [item], outDir: newOut, name: "out").validate(), [])
    }

    func test_validate_flags_unwritable_root_output() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        let bad = URL(fileURLWithPath: "/no-such-root-\(UUID().uuidString)/x")
        XCTAssertEqual(opts(items: [item], outDir: bad, name: "out").validate(), [.outputDirectoryInvalid])
    }

    func test_validate_rejects_bad_archive_names() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        for bad in ["a/b", "a:b", ".", "..", "   "] {
            XCTAssertEqual(opts(items: [item], outDir: dir, name: bad).validate(), [.invalidArchiveName],
                           "expected \(bad) invalid")
        }
    }

    func test_commonParent_same_dir_multi() {
        let base = URL(fileURLWithPath: "/a/b")
        let items = [base.appendingPathComponent("x"), base.appendingPathComponent("y")]
        XCTAssertEqual(CompressionOptions.commonParent(of: items).path, "/a/b")
    }

    func test_commonParent_single_item_is_parent() {
        let items = [URL(fileURLWithPath: "/a/b/x")]
        XCTAssertEqual(CompressionOptions.commonParent(of: items).path, "/a/b")
    }

    func test_commonParent_cross_dir() {
        let items = [URL(fileURLWithPath: "/a/b/x/deep"), URL(fileURLWithPath: "/a/b/y")]
        XCTAssertEqual(CompressionOptions.commonParent(of: items).path, "/a/b")
    }

    func test_relativeItemPaths_same_dir() {
        let base = URL(fileURLWithPath: "/a/b")
        let items = [base.appendingPathComponent("x"), base.appendingPathComponent("y")]
        XCTAssertEqual(opts(items: items, outDir: base).relativeItemPaths, ["x", "y"])
    }

    func test_relativeItemPaths_cross_dir_preserves_structure() {
        let items = [URL(fileURLWithPath: "/a/b/x/deep"), URL(fileURLWithPath: "/a/b/y")]
        XCTAssertEqual(opts(items: items, outDir: URL(fileURLWithPath: "/a/b")).relativeItemPaths, ["x/deep", "y"])
    }

    func test_defaults_single_folder_names_after_it() throws {
        let parent = try tempDir()
        let folder = parent.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let d = CompressionOptions.defaults(items: [folder])
        XCTAssertEqual(d.archiveName, "proj")
        XCTAssertEqual(d.outputDirectory.path, parent.path)
        XCTAssertEqual(d.format, .sevenZip)
        XCTAssertEqual(d.level, .normal)
        XCTAssertTrue(d.encryptHeader)
        XCTAssertTrue(d.excludeDotfiles)
    }

    func test_defaults_single_file_keeps_original_name() {
        let d = CompressionOptions.defaults(items: [URL(fileURLWithPath: "/a/b/a.txt")])
        XCTAssertEqual(d.archiveName, "a.txt")
    }

    func test_defaults_multi_uses_parent_dir_name() {
        let items = [URL(fileURLWithPath: "/a/b/x"), URL(fileURLWithPath: "/a/b/y")]
        XCTAssertEqual(CompressionOptions.defaults(items: items).archiveName, "b")
    }

    func test_resolveOutput_appends_extension() throws {
        let dir = try tempDir()
        let item = dir.appendingPathComponent("a.txt"); try "x".write(to: item, atomically: true, encoding: .utf8)
        let out7z = try opts(items: [item], outDir: dir, name: "pack", format: .sevenZip).resolveOutput()
        XCTAssertEqual(out7z, dir.appendingPathComponent("pack.7z"))
        let outzip = try opts(items: [item], outDir: dir, name: "pack", format: .zip).resolveOutput()
        XCTAssertEqual(outzip, dir.appendingPathComponent("pack.zip"))
    }

    func test_resolveOutput_throws_on_invalid() {
        let bad = URL(fileURLWithPath: "/no-root-\(UUID().uuidString)/x")
        XCTAssertThrowsError(try opts(items: [URL(fileURLWithPath: "/a/x")], outDir: bad, name: "p").resolveOutput()) { e in
            guard case ArchiveError.invalidDestination = e else { return XCTFail("expected invalidDestination") }
        }
    }

    func test_numberedFile_inserts_before_extension() {
        var existing: Set<String> = ["/d/Archive.7z", "/d/Archive 2.7z"]
        let out = CompressionOptions.numberedFile(base: URL(fileURLWithPath: "/d/Archive.7z"),
                                                  exists: { existing.contains($0.path) })
        XCTAssertEqual(out, URL(fileURLWithPath: "/d/Archive 3.7z"))
        _ = existing
    }

    func test_arguments_7z_with_password_and_header_and_dotfiles() {
        let base = URL(fileURLWithPath: "/a/b")
        let o = opts(items: [base.appendingPathComponent("x")], outDir: base, name: "p",
                     format: .sevenZip, level: .maximum, password: "PW",
                     encryptHeader: true, excludeDotfiles: true)
        let args = o.arguments(output: URL(fileURLWithPath: "/a/b/p.7z"))
        XCTAssertEqual(args, ["a", "-t7z", "-mx=7", "-bb1", "-y", "-pPW", "-mhe=on", "-xr!.*", "/a/b/p.7z", "x"])
    }

    func test_arguments_zip_uses_aes_not_mhe() {
        let base = URL(fileURLWithPath: "/a/b")
        let o = opts(items: [base.appendingPathComponent("x")], outDir: base, name: "p",
                     format: .zip, level: .normal, password: "PW",
                     encryptHeader: true, excludeDotfiles: false)
        let args = o.arguments(output: URL(fileURLWithPath: "/a/b/p.zip"))
        XCTAssertEqual(args, ["a", "-tzip", "-mx=5", "-bb1", "-y", "-pPW", "-mem=AES256", "/a/b/p.zip", "x"])
    }

    func test_arguments_no_password_no_encryption_flags() {
        let base = URL(fileURLWithPath: "/a/b")
        let o = opts(items: [base.appendingPathComponent("x")], outDir: base, name: "p",
                     format: .sevenZip, level: .store, password: "", excludeDotfiles: false)
        let args = o.arguments(output: URL(fileURLWithPath: "/a/b/p.7z"))
        XCTAssertEqual(args, ["a", "-t7z", "-mx=0", "-bb1", "-y", "/a/b/p.7z", "x"])
    }

    func test_totalFileCount_counts_regular_files_skipping_dotfiles() throws {
        let dir = try tempDir()
        let sub = dir.appendingPathComponent("s"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("f1.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: sub.appendingPathComponent("f2.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CompressionProgress.totalFileCount(items: [dir], excludeDotfiles: true), 2)
        XCTAssertEqual(CompressionProgress.totalFileCount(items: [dir], excludeDotfiles: false), 3)
    }
}

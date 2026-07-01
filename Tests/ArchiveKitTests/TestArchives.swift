import Foundation
import XCTest

/// Creates real archives in a temp dir using the system 7z, for integration tests.
enum TestArchives {
    static let sevenZipURL = URL(fileURLWithPath: "/opt/homebrew/bin/7z")

    static func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aktests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func run7z(_ args: [String], cwd: URL) throws -> Int32 {
        let p = Process()
        p.executableURL = sevenZipURL
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Archive whose only top-level entry is a directory `project/`.
    static func singleTopDirArchive() throws -> URL {
        let dir = try makeTempDir()
        let proj = dir.appendingPathComponent("project/src")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "hello".write(to: proj.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try run7z(["a", "-bd", "single.7z", "project"], cwd: dir)
        return dir.appendingPathComponent("single.7z")
    }

    /// Header-encrypted archive (needs password even to list).
    static func headerEncryptedArchive(password: String) throws -> URL {
        let dir = try makeTempDir()
        try "secret".write(to: dir.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        _ = try run7z(["a", "-bd", "-p\(password)", "-mhe=on", "enc.7z", "s.txt"], cwd: dir)
        return dir.appendingPathComponent("enc.7z")
    }
}

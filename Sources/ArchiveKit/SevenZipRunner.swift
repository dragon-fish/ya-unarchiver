import Foundation

public final class SevenZipRunner: Sendable {
    private let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    struct RunResult { let code: Int32; let stdout: String; let stderr: String }

    private func run(_ arguments: [String]) throws -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ArchiveError.binaryNotFound
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw ArchiveError.binaryNotFound
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            code: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Returns the 7-Zip version token (e.g. "25.01"), parsed from the banner.
    public func version() throws -> String {
        let result = try run(["i"])   // `7zz i` prints the banner + info, exits 0
        let source = result.stdout.isEmpty ? result.stderr : result.stdout
        let firstLine = source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        if let range = firstLine.range(of: #"[0-9]+\.[0-9]+"#, options: .regularExpression) {
            return String(firstLine[range])
        }
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    public func list(archive: URL, password: String?) throws -> [ArchiveEntry] {
        var args = ["l", "-slt"]
        // -p with no password still disables the interactive prompt.
        args.append("-p\(password ?? "")")
        args.append(archive.path)

        let result = try run(args)
        if result.code == 0 {
            return SltParser.parse(result.stdout)
        }
        // Non-zero exit: classify.
        let combined = result.stdout + result.stderr
        if combined.contains("Headers Error")
            || combined.contains("Wrong password")
            || combined.contains("Cannot open encrypted archive") {
            throw ArchiveError.needsPassword
        }
        throw ArchiveError.corrupted(combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func extract(archive: URL, entries: [String]?, to destination: URL, password: String?) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["x", "-bd", "-y", "-o\(destination.path)", "-p\(password ?? "")", archive.path]
        if let entries {
            args.append(contentsOf: entries)
        }
        let result = try run(args)
        guard result.code == 0 else {
            let combined = result.stdout + result.stderr
            if combined.contains("Wrong password") || combined.contains("Headers Error") {
                throw ArchiveError.wrongPassword
            }
            throw ArchiveError.executionFailed(
                code: result.code,
                message: combined.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Extracts (all of, or a selected subset of) an archive so that `finalFolder`
    /// directly contains the result, with no `foo/foo` double-nesting.
    ///
    /// - `entries == nil` extracts everything; a non-nil `entries` extracts only those
    ///   archive-internal paths.
    /// - When `singleTopLevelDir` is non-nil, the archive's lone top-level directory is a
    ///   redundant prefix: extract into a temp dir on the SAME volume as `finalFolder`
    ///   (so the move is a cheap rename), then move `temp/<singleTopLevelDir>` into place,
    ///   stripping the prefix. Because every entry (and thus any selected subset) lives
    ///   under that lone top dir, `temp/<singleTopLevelDir>` always exists.
    /// - When `singleTopLevelDir` is nil, entries are placed under `finalFolder` directly.
    ///
    /// `finalFolder` must not already exist (the caller resolves collisions first).
    public func extract(archive: URL, entries: [String]?, singleTopLevelDir: String?,
                        to finalFolder: URL, password: String?) throws {
        let fm = FileManager.default
        guard let topDir = singleTopLevelDir else {
            try extract(archive: archive, entries: entries, to: finalFolder, password: password)
            return
        }
        let parent = finalFolder.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".7zip-swiftui-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try extract(archive: archive, entries: entries, to: temp, password: password)
        try fm.moveItem(at: temp.appendingPathComponent(topDir), to: finalFolder)
    }
}

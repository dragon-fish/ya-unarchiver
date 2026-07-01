import Foundation

public final class SevenZipRunner {
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
}

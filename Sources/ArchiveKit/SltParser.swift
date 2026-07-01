import Foundation

public enum SltParser {

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func parse(_ output: String) -> [ArchiveEntry] {
        // Entries live after the "----------" separator. Everything before it
        // (the archive-properties block) is ignored.
        guard let sepRange = output.range(of: "\n----------\n")
                ?? output.range(of: "----------\n") else {
            return []
        }
        let body = output[sepRange.upperBound...]

        var entries: [ArchiveEntry] = []
        // Blocks separated by blank lines.
        for rawBlock in body.components(separatedBy: "\n\n") {
            var fields: [String: String] = [:]
            for line in rawBlock.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let eq = line.range(of: " = ") else { continue }
                let key = String(line[line.startIndex..<eq.lowerBound])
                let value = String(line[eq.upperBound...])
                fields[key] = value
            }
            guard let path = fields["Path"], !path.isEmpty else { continue }

            let attributes = fields["Attributes"] ?? ""
            let isDir = fields["Folder"] == "+"
                || attributes.split(separator: " ").first?.contains("D") == true

            let modified = fields["Modified"].flatMap { $0.isEmpty ? nil : dateFormatter.date(from: $0) }

            entries.append(ArchiveEntry(
                path: path,
                size: Int64(fields["Size"] ?? "") ?? 0,
                packedSize: Int64(fields["Packed Size"] ?? "") ?? 0,
                modified: modified,
                isDirectory: isDir,
                isEncrypted: fields["Encrypted"] == "+"
            ))
        }
        return entries
    }
}

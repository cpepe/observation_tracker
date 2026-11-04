import Foundation

struct CSVTable: Sendable {
    var header: [String]
    var rows: [[String]]
    var delimiter: Unicode.Scalar

    var delimiterName: String {
        switch delimiter {
        case ";": "Semicolon"
        case "\t": "Tab"
        default: "Comma"
        }
    }
}

enum CSVParseError: LocalizedError {
    case unreadableText
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadableText: "The file isn't readable text."
        case .empty: "The file has no header row."
        }
    }
}

/// RFC 4180 parser with delimiter auto-detection (comma, semicolon or tab).
enum CSVParser {
    /// Decodes file bytes as UTF-8 (falling back to Windows-1252) without a byte-order mark.
    static func decodeText(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        return String(data: bytes, encoding: .windowsCP1252)
    }

    static func parse(data: Data) throws -> CSVTable {
        guard let text = decodeText(data) else { throw CSVParseError.unreadableText }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> CSVTable {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        let delimiter = detectDelimiter(scalars)

        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var i = 0
        let n = scalars.count

        func endField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
        }

        while i < n {
            if i & 0xFFFF == 0, Task.isCancelled { throw CancellationError() }
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < n && scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c == "\r" {
                if i + 1 < n && scalars[i + 1] == "\n" { i += 1 }
                endRecord()
            } else if c == "\n" {
                endRecord()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty || inQuotes {
            endRecord()
        }

        guard let header = records.first, !(header.count == 1 && header[0].isEmpty) else {
            throw CSVParseError.empty
        }
        let rows = records.dropFirst().filter { !($0.count == 1 && $0[0].isEmpty) }
        return CSVTable(header: header, rows: Array(rows), delimiter: delimiter)
    }

    /// Picks the most frequent unquoted delimiter in the header row.
    static func detectDelimiter(_ scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for c in scalars {
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r" { break }
            if counts[c] != nil { counts[c]! += 1 }
        }
        let candidates: [Unicode.Scalar] = [",", ";", "\t"]
        let best = candidates.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ","
        return (counts[best] ?? 0) > (counts[","] ?? 0) ? best : ","
    }
}

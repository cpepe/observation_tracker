import Foundation

/// RFC 4180 CSV encoder for project exports.
enum CSVWriter {
    static let byteOrderMark = "\u{FEFF}"

    /// Every observation (oldest first) and every field, hidden ones included.
    static func csv(fields: [FieldDefinition], observations: [ObservationSnapshot], timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone

        var out = byteOrderMark
        out.reserveCapacity(observations.count * (24 + fields.count * 8))
        out += (["timestamp"] + fields.map(\.name)).map(escape).joined(separator: ",")
        out += "\r\n"

        for obs in observations.sorted(by: ObservationSnapshot.ascending) {
            var cells = [formatter.string(from: obs.timestamp)]
            cells.reserveCapacity(fields.count + 1)
            for field in fields {
                cells.append(cell(for: obs.values[field.id], type: field.type))
            }
            out += cells.joined(separator: ",")
            out += "\r\n"
        }
        return out
    }

    static func data(fields: [FieldDefinition], observations: [ObservationSnapshot], timeZone: TimeZone = .current) -> Data {
        Data(csv(fields: fields, observations: observations, timeZone: timeZone).utf8)
    }

    static func cell(for value: FieldValue?, type: FieldType) -> String {
        guard let value, value.matches(type) else { return "" }
        switch value {
        case .integer(let i): return String(i)
        case .decimal(let d): return decimalString(d)
        case .text(let s): return escape(s)
        }
    }

    /// Shortest round-trip representation, always with a fractional part
    /// (`9.0`, not `9`) so a re-import infers Decimal rather than Integer.
    static func decimalString(_ d: Double) -> String {
        var s = "\(d)"
        if !s.contains(".") && !s.contains("e") && !s.contains("E") { s += ".0" }
        return s
    }

    static func escape(_ s: String) -> String {
        let needsQuotes = s.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `<project name>_<YYYY-MM-DD>.csv` with characters invalid in file names replaced by `-`.
    static func fileName(projectName: String, date: Date = .now, calendar: Calendar = .current) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = String(projectName.unicodeScalars.map { invalid.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(cleaned.isEmpty ? "Project" : cleaned)_\(stamp).csv"
    }
}

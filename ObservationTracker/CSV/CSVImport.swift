import Foundation

// MARK: - Timestamps

/// Parses the timestamp formats the importer accepts.
final class TimestampParser {
    private let isoWithOffset: ISO8601DateFormatter
    private let isoWithOffsetFractional: ISO8601DateFormatter
    private let posixFormatters: [DateFormatter]
    private let localeFormatters: [DateFormatter]

    init(timeZone: TimeZone = .current, locale: Locale = .current) {
        isoWithOffset = ISO8601DateFormatter()
        isoWithOffset.formatOptions = [.withInternetDateTime]
        isoWithOffsetFractional = ISO8601DateFormatter()
        isoWithOffsetFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // ISO 8601 without an offset and `yyyy-MM-dd HH:mm[:ss]` use the device's time zone.
        posixFormatters = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = format
            return f
        }

        // The device locale's short numeric date, with optional time (e.g. 11/4/2026 8:15 AM).
        let date = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "M/d/y"
        let time = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "h:mm a"
        let timeSec = DateFormatter.dateFormat(fromTemplate: "jmmss", options: 0, locale: locale) ?? "h:mm:ss a"
        localeFormatters = [
            "\(date) \(timeSec)", "\(date), \(timeSec)",
            "\(date) \(time)", "\(date), \(time)",
            date,
        ].map { format in
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.dateFormat = format
            f.isLenient = false
            return f
        }
    }

    func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = isoWithOffset.date(from: s) ?? isoWithOffsetFractional.date(from: s) { return d }
        for f in posixFormatters { if let d = f.date(from: s) { return d } }
        for f in localeFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }
}

// MARK: - Column analysis

struct ColumnInfo: Hashable, Sendable {
    var nonEmptyCount = 0
    var fitsInteger = true
    var fitsDecimal = true

    /// All whole numbers → Integer; all numbers → Decimal; anything else (or no values) → Text.
    var inferredType: FieldType {
        if nonEmptyCount == 0 { return .text }
        if fitsInteger { return .integer }
        if fitsDecimal { return .decimal }
        return .text
    }

    /// Types every value in the column fits (Text always fits).
    var allowedTypes: [FieldType] {
        FieldType.allCases.filter { type in
            switch type {
            case .integer: fitsInteger
            case .decimal: fitsDecimal
            case .text: true
            }
        }
    }
}

struct ImportTarget: Hashable, Sendable {
    let column: Int
    let fieldID: UUID
    let type: FieldType
}

struct ImportedRow: Sendable {
    let timestamp: Date
    let values: [UUID: FieldValue]
}

struct ImportRowError: Identifiable, Sendable {
    /// Spreadsheet-style row number (the header is row 1).
    let row: Int
    let reason: String
    var id: Int { row }
}

struct ImportEvaluation: Sendable {
    var rows: [ImportedRow] = []
    var duplicateCount = 0
    var errors: [ImportRowError] = []
}

enum CSVImportAnalyzer {
    static let timestampNames = ["timestamp", "datetime", "date", "time"]

    /// The column named timestamp, datetime, date or time (in that priority).
    static func timestampColumn(in header: [String]) -> Int? {
        let normalized = header.map(FieldNameRules.normalize)
        for name in timestampNames {
            if let i = normalized.firstIndex(of: name) { return i }
        }
        return nil
    }

    static func usesDecimalComma(_ table: CSVTable) -> Bool { table.delimiter == ";" }

    static func columnInfo(table: CSVTable, column: Int) -> ColumnInfo {
        let decimalComma = usesDecimalComma(table)
        var info = ColumnInfo()
        for row in table.rows where column < row.count {
            let s = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            info.nonEmptyCount += 1
            if info.fitsInteger && parseNumber(s, as: .integer, decimalComma: decimalComma) == nil { info.fitsInteger = false }
            if info.fitsDecimal && parseNumber(s, as: .decimal, decimalComma: decimalComma) == nil { info.fitsDecimal = false }
        }
        return info
    }

    /// Parses a trimmed, non-empty numeric cell. Returns nil when it doesn't fit the type.
    static func parseNumber(_ s: String, as type: FieldType, decimalComma: Bool) -> FieldValue? {
        switch type {
        case .integer:
            return Int(s).map(FieldValue.integer)
        case .decimal:
            let normalized = decimalComma ? s.replacingOccurrences(of: ",", with: ".") : s
            guard let d = Double(normalized), d.isFinite else { return nil }
            return .decimal(d)
        case .text:
            return .text(s)
        }
    }

    private struct DuplicateKey: Hashable {
        let second: Int64
        let values: [UUID: FieldValue]
    }

    /// Validates every row against the chosen targets and drops duplicates of
    /// existing observations (same second, same value for every imported field).
    static func evaluate(
        table: CSVTable,
        timestampColumn: Int,
        targets: [ImportTarget],
        existing: [ObservationSnapshot],
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) throws -> ImportEvaluation {
        let parser = TimestampParser(timeZone: timeZone, locale: locale)
        let decimalComma = usesDecimalComma(table)
        let targetIDs = Set(targets.map(\.fieldID))
        let columnCount = table.header.count

        var seen = Set<DuplicateKey>()
        seen.reserveCapacity(existing.count + table.rows.count)
        for obs in existing {
            seen.insert(DuplicateKey(second: second(obs.timestamp), values: obs.values.filter { targetIDs.contains($0.key) }))
        }

        var result = ImportEvaluation()
        for (index, row) in table.rows.enumerated() {
            if index & 0x3FF == 0, Task.isCancelled { throw CancellationError() }
            let rowNumber = index + 2

            let trimmed = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if trimmed.allSatisfy(\.isEmpty) { continue }

            if row.count > columnCount {
                result.errors.append(.init(row: rowNumber, reason: "Has \(row.count) cells but the header has \(columnCount)."))
                continue
            }

            let rawTime = timestampColumn < trimmed.count ? trimmed[timestampColumn] : ""
            guard let timestamp = parser.parse(rawTime) else {
                let reason = rawTime.isEmpty ? "Missing timestamp." : "Can't read the timestamp “\(rawTime)”."
                result.errors.append(.init(row: rowNumber, reason: reason))
                continue
            }

            var values: [UUID: FieldValue] = [:]
            var failure: String?
            for target in targets where target.column < trimmed.count {
                let cell = trimmed[target.column]
                if cell.isEmpty { continue }
                if let value = parseNumber(cell, as: target.type, decimalComma: decimalComma) {
                    values[target.fieldID] = value
                } else {
                    let header = table.header[target.column].trimmingCharacters(in: .whitespaces)
                    let kind = target.type == .integer ? "a whole number" : "a number"
                    failure = "“\(cell)” in \(header) isn't \(kind)."
                    break
                }
            }
            if let failure {
                result.errors.append(.init(row: rowNumber, reason: failure))
                continue
            }

            let key = DuplicateKey(second: second(timestamp), values: values)
            if seen.contains(key) {
                result.duplicateCount += 1
                continue
            }
            seen.insert(key)
            result.rows.append(ImportedRow(timestamp: timestamp, values: values))
        }
        return result
    }

    private static func second(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970))
    }
}

import Foundation

// MARK: - Field definitions

enum FieldType: String, Codable, CaseIterable, Identifiable, Sendable {
    case integer, decimal, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .integer: "Integer"
        case .decimal: "Decimal"
        case .text: "Text"
        }
    }

    var isNumeric: Bool { self != .text }
}

struct FieldDefinition: Codable, Identifiable, Hashable, Sendable {
    let id: UUID                // never changes
    var name: String            // renamable
    let type: FieldType         // fixed at creation
    var isHidden: Bool          // hidden from entry, chart, stats; still exported

    init(id: UUID = UUID(), name: String, type: FieldType, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.isHidden = isHidden
    }
}

enum FieldValue: Hashable, Sendable {
    case integer(Int)
    case decimal(Double)
    case text(String)

    var doubleValue: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .decimal(let d): d
        case .text: nil
        }
    }

    func matches(_ type: FieldType) -> Bool {
        switch (self, type) {
        case (.integer, .integer), (.decimal, .decimal), (.text, .text): true
        default: false
        }
    }
}

extension FieldValue: Codable {
    private enum CodingKeys: String, CodingKey { case i, d, t }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try c.decodeIfPresent(Int.self, forKey: .i) { self = .integer(i) }
        else if let d = try c.decodeIfPresent(Double.self, forKey: .d) { self = .decimal(d) }
        else { self = .text(try c.decode(String.self, forKey: .t)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let i): try c.encode(i, forKey: .i)
        case .decimal(let d): try c.encode(d, forKey: .d)
        case .text(let t): try c.encode(t, forKey: .t)
        }
    }
}

// MARK: - Field name rules

enum FieldNameRules {
    static let reserved = "timestamp"

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns an error message, or nil when the name is valid.
    static func validate(_ name: String, otherNames: [String]) -> String? {
        let n = normalize(name)
        if n.isEmpty { return "Enter a field name." }
        if n == reserved { return "“timestamp” is reserved." }
        if otherNames.contains(where: { normalize($0) == n }) { return "Another field already uses this name." }
        return nil
    }
}

// MARK: - Chart settings

enum ChartMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case raw, runningTotal, dailyTotals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: "Values"
        case .runningTotal: "Running Total"
        case .dailyTotals: "Daily Totals"
        }
    }
}

enum DateRangeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case days7, days30, days90, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7: "Last 7 Days"
        case .days30: "Last 30 Days"
        case .days90: "Last 90 Days"
        case .all: "All"
        }
    }

    var dayCount: Int? {
        switch self {
        case .days7: 7
        case .days30: 30
        case .days90: 90
        case .all: nil
        }
    }

    /// Start of the first calendar day in the range, or nil for All.
    func startDate(now: Date, calendar: Calendar) -> Date? {
        guard let n = dayCount else { return nil }
        return calendar.date(byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: now))
    }
}

struct ChartSettings: Codable, Hashable, Sendable {
    var mode: ChartMode = .raw
    var range: DateRangeOption = .all
    var hiddenSeries: Set<UUID> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ChartMode.self, forKey: .mode) ?? .raw
        range = try c.decodeIfPresent(DateRangeOption.self, forKey: .range) ?? .all
        hiddenSeries = try c.decodeIfPresent(Set<UUID>.self, forKey: .hiddenSeries) ?? []
    }
}

// MARK: - Value snapshots

/// An immutable copy of an observation, safe to hand to background tasks.
struct ObservationSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let createdAt: Date
    let values: [UUID: FieldValue]

    /// Timestamp order, ties broken by creation time.
    static func ascending(_ a: ObservationSnapshot, _ b: ObservationSnapshot) -> Bool {
        if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
        return a.createdAt < b.createdAt
    }
}

extension Date {
    /// Drops sub-second precision so stored times match their CSV form exactly.
    var truncatedToSecond: Date {
        Date(timeIntervalSince1970: floor(timeIntervalSince1970))
    }
}

// MARK: - Compact binary storage for observation values

/// Observation values are stored as a compact binary blob instead of a SwiftData
/// composite attribute: SwiftData on iOS 17 is unreliable with enums that carry
/// associated values, and this keeps decoding fast at 50,000 observations.
enum FieldValueCodec {
    private static let version: UInt8 = 1

    static func encode(_ values: [UUID: FieldValue]) -> Data {
        var data = Data()
        data.reserveCapacity(1 + values.count * 26)
        data.append(version)
        for (id, value) in values {
            withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
            switch value {
            case .integer(let i):
                data.append(0)
                withUnsafeBytes(of: Int64(i).littleEndian) { data.append(contentsOf: $0) }
            case .decimal(let d):
                data.append(1)
                withUnsafeBytes(of: d.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            case .text(let s):
                data.append(2)
                let utf8 = Data(s.utf8)
                withUnsafeBytes(of: UInt32(utf8.count).littleEndian) { data.append(contentsOf: $0) }
                data.append(utf8)
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [UUID: FieldValue] {
        var result: [UUID: FieldValue] = [:]
        data.withUnsafeBytes { raw in
            let n = raw.count
            guard n > 0, raw[0] == version else { return }
            var o = 1
            while o + 17 <= n {
                var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                withUnsafeMutableBytes(of: &uuid) {
                    $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[o..<(o + 16)]))
                }
                o += 16
                let tag = raw[o]
                o += 1
                let id = UUID(uuid: uuid)
                switch tag {
                case 0:
                    guard o + 8 <= n else { return }
                    let v = Int64(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int64.self))
                    result[id] = .integer(Int(v))
                    o += 8
                case 1:
                    guard o + 8 <= n else { return }
                    let bits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt64.self))
                    result[id] = .decimal(Double(bitPattern: bits))
                    o += 8
                case 2:
                    guard o + 4 <= n else { return }
                    let len = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
                    o += 4
                    guard o + len <= n else { return }
                    result[id] = .text(String(decoding: UnsafeRawBufferPointer(rebasing: raw[o..<(o + len)]), as: UTF8.self))
                    o += len
                default:
                    return
                }
            }
        }
        return result
    }
}

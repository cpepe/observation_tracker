import Foundation

struct SeriesDescriptor: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    /// Palette slot, assigned by position among all numeric fields so hiding
    /// a field never shifts another field's color.
    let colorIndex: Int
    let type: FieldType
}

/// One x position on the chart: an observation (Values, Running Total) or a day (Daily Totals).
struct ChartRow: Sendable {
    let date: Date
    let values: [UUID: Double]
}

struct ChartPoint: Identifiable, Sendable {
    let id: Int
    let seriesID: UUID
    let date: Date
    let value: Double
}

struct ChartData: Sendable {
    var mode: ChartMode = .raw
    var rows: [ChartRow] = []
    var points: [ChartPoint] = []

    /// Row closest to a selected x value.
    func nearestRow(to date: Date) -> ChartRow? {
        guard !rows.isEmpty else { return nil }
        var lo = 0, hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].date < date { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(rows[lo - 1].date.timeIntervalSince(date)) <= abs(rows[lo].date.timeIntervalSince(date)) {
            return rows[lo - 1]
        }
        return rows[lo]
    }

    var span: TimeInterval {
        guard let first = rows.first, let last = rows.last else { return 0 }
        return last.date.timeIntervalSince(first.date)
    }
}

struct DaySection: Identifiable, Sendable {
    let id: Date              // start of day
    var observations: [ObservationSnapshot]
}

struct FieldStats: Identifiable, Sendable {
    let series: SeriesDescriptor
    var count = 0
    var sum = 0.0
    /// Exact integer sum, nil for decimals or once it overflows 64 bits.
    var integerSum: Int?
    var min: (value: Double, date: Date)?
    var max: (value: Double, date: Date)?
    var latest: (value: Double, date: Date)?
    var mean: Double? { count > 0 ? sum / Double(count) : nil }
    var dailyAverage: Double?

    var id: UUID { series.id }
}

/// Everything the project screen derives from its observations. Built from
/// value snapshots so it can run off the main actor.
struct ProjectAnalysis: Sendable {
    var totalCount = 0
    /// Observations in the selected range, newest first.
    var inRange: [ObservationSnapshot] = []
    var sections: [DaySection] = []
    /// Visible numeric fields in template order.
    var series: [SeriesDescriptor] = []
    var chart = ChartData()
    var stats: [FieldStats] = []
    var showsPointMarkers = true

    static func compute(
        snapshots: [ObservationSnapshot],          // oldest first
        fields: [FieldDefinition],
        settings: ChartSettings,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ProjectAnalysis {
        var result = ProjectAnalysis()
        result.totalCount = snapshots.count

        var colorIndex = 0
        for field in fields where field.type.isNumeric {
            if !field.isHidden {
                result.series.append(SeriesDescriptor(id: field.id, name: field.name, colorIndex: colorIndex, type: field.type))
            }
            colorIndex += 1
        }

        let start = settings.range.startDate(now: now, calendar: calendar)
        let firstInRange = start.map { s in snapshots.firstIndex { $0.timestamp >= s } ?? snapshots.count } ?? 0
        let ascendingInRange = snapshots[firstInRange...]
        result.inRange = ascendingInRange.reversed()
        result.showsPointMarkers = ascendingInRange.count <= 100

        // Day sections, newest first.
        var sections: [DaySection] = []
        for obs in result.inRange {
            let day = calendar.startOfDay(for: obs.timestamp)
            if sections.last?.id == day {
                sections[sections.count - 1].observations.append(obs)
            } else {
                sections.append(DaySection(id: day, observations: [obs]))
            }
        }
        result.sections = sections

        result.chart = chartData(
            mode: settings.mode, all: snapshots, firstInRange: firstInRange,
            series: result.series, calendar: calendar
        )

        // Daily average uses calendar days in the range; for All, from the first observation's day.
        let dayCount: Int
        if let n = settings.range.dayCount {
            dayCount = n
        } else if let first = snapshots.first {
            let last = Swift.max(now, snapshots.last?.timestamp ?? now)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first.timestamp), to: calendar.startOfDay(for: last)).day ?? 0
            dayCount = Swift.max(1, days + 1)
        } else {
            dayCount = 1
        }
        result.stats = result.series.map { stats(for: $0, in: ascendingInRange, dayCount: dayCount) }
        return result
    }

    private static func chartData(
        mode: ChartMode,
        all: [ObservationSnapshot],
        firstInRange: Int,
        series: [SeriesDescriptor],
        calendar: Calendar
    ) -> ChartData {
        var data = ChartData(mode: mode)
        let ids = series.map(\.id)

        switch mode {
        case .raw:
            for obs in all[firstInRange...] {
                var values: [UUID: Double] = [:]
                for id in ids { if let v = obs.values[id]?.doubleValue { values[id] = v } }
                if !values.isEmpty { data.rows.append(ChartRow(date: obs.timestamp, values: values)) }
            }

        case .runningTotal:
            // Always counts from the project's first observation, so changing the range never changes a value.
            // Totals are kept as Double, which cannot overflow the way a 64-bit Int sum can.
            var totals = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.0) })
            for (i, obs) in all.enumerated() {
                for id in ids { if let v = obs.values[id]?.doubleValue { totals[id, default: 0] += v } }
                if i >= firstInRange { data.rows.append(ChartRow(date: obs.timestamp, values: totals)) }
            }

        case .dailyTotals:
            var currentDay: Date?
            var sums: [UUID: Double] = [:]
            func flush() {
                if let day = currentDay, !sums.isEmpty { data.rows.append(ChartRow(date: day, values: sums)) }
            }
            for obs in all[firstInRange...] {
                let day = calendar.startOfDay(for: obs.timestamp)
                if day != currentDay {
                    flush()
                    currentDay = day
                    sums = [:]
                }
                for id in ids { if let v = obs.values[id]?.doubleValue { sums[id, default: 0] += v } }
            }
            flush()
        }

        var nextID = 0
        for row in data.rows {
            for id in ids {
                if let v = row.values[id] {
                    data.points.append(ChartPoint(id: nextID, seriesID: id, date: row.date, value: v))
                    nextID += 1
                }
            }
        }
        return data
    }

    private static func stats(for series: SeriesDescriptor, in observations: ArraySlice<ObservationSnapshot>, dayCount: Int) -> FieldStats {
        var s = FieldStats(series: series)
        var intSum: Int? = series.type == .integer ? 0 : nil
        for obs in observations {
            guard let value = obs.values[series.id], let v = value.doubleValue else { continue }
            s.count += 1
            s.sum += v
            if case .integer(let i) = value, let current = intSum {
                let (r, overflow) = current.addingReportingOverflow(i)
                intSum = overflow ? nil : r
            }
            if s.min == nil || v < s.min!.value { s.min = (v, obs.timestamp) }
            if s.max == nil || v > s.max!.value { s.max = (v, obs.timestamp) }
            s.latest = (v, obs.timestamp)
        }
        s.integerSum = s.count > 0 ? intSum : nil
        s.dailyAverage = s.count > 0 ? s.sum / Double(dayCount) : nil
        return s
    }
}

import Charts
import SwiftUI

struct ProjectChartView: View {
    let analysis: ProjectAnalysis
    let settings: ChartSettings
    let onChangeMode: (ChartMode) -> Void
    let onToggleSeries: (UUID) -> Void
    let onShowAllSeries: () -> Void
    let onShowAllTime: () -> Void
    let onAdd: () -> Void

    @State private var selectedDate: Date?

    private var visibleSeries: [SeriesDescriptor] {
        analysis.series.filter { !settings.hiddenSeries.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Chart Mode", selection: Binding(get: { settings.mode }, set: onChangeMode)) {
                ForEach(ChartMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if !analysis.series.isEmpty {
                legend
            }

            chartArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .onChange(of: settings.mode) { selectedDate = nil }
    }

    // MARK: Legend

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(analysis.series) { series in
                    let isOn = !settings.hiddenSeries.contains(series.id)
                    Button {
                        onToggleSeries(series.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isOn ? Palette.color(series.colorIndex) : Color.secondary.opacity(0.3))
                                .frame(width: 10, height: 10)
                            Text(series.name)
                                .strikethrough(!isOn)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(isOn ? 0.12 : 0.05)))
                        .foregroundStyle(isOn ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(series.name)
                    .accessibilityValue(isOn ? "Shown" : "Hidden")
                    .accessibilityHint("Toggles this series on the chart")
                }
            }
        }
    }

    // MARK: Chart and empty states

    @ViewBuilder
    private var chartArea: some View {
        let visibleIDs = Set(visibleSeries.map(\.id))
        let points = analysis.chart.points.filter { visibleIDs.contains($0.seriesID) }

        if analysis.totalCount == 0 {
            ContentUnavailableView {
                Label("No Observations", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Log your first reading to start the chart.")
            } actions: {
                Button("Add Observation", action: onAdd).buttonStyle(.borderedProminent)
            }
        } else if analysis.series.isEmpty {
            ContentUnavailableView("Nothing to Chart", systemImage: "chart.xyaxis.line",
                                   description: Text("This project has no visible numeric fields."))
        } else if visibleSeries.isEmpty {
            ContentUnavailableView {
                Label("All Series Hidden", systemImage: "eye.slash")
            } actions: {
                Button("Show All", action: onShowAllSeries).buttonStyle(.bordered)
            }
        } else if points.isEmpty {
            ContentUnavailableView {
                Label("No Data in This Range", systemImage: "calendar.badge.exclamationmark")
            } actions: {
                if settings.range != .all {
                    Button("Show All Time", action: onShowAllTime).buttonStyle(.bordered)
                }
            }
        } else {
            chart(points: points)
        }
    }

    private func chart(points: [ChartPoint]) -> some View {
        let series = visibleSeries
        let names = Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0.name) })
        let mode = analysis.chart.mode
        let selectedRow = selectedDate.flatMap { analysis.chart.nearestRow(to: $0) }

        return Chart {
            ForEach(points) { point in
                let name = names[point.seriesID] ?? ""
                if mode == .dailyTotals {
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Total", point.value)
                    )
                    .foregroundStyle(by: .value("Series", name))
                    .position(by: .value("Series", name))
                    .accessibilityLabel(name)
                    .accessibilityValue("\(formatted(point.value)) on \(point.date.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(mode == .raw ? "Value" : "Running Total", point.value),
                        series: .value("Series", name)
                    )
                    .foregroundStyle(by: .value("Series", name))
                    .interpolationMethod(.linear)
                    .accessibilityLabel(name)
                    .accessibilityValue("\(formatted(point.value)) at \(point.date.formatted(date: .abbreviated, time: .shortened))")

                    if mode == .raw && analysis.showsPointMarkers {
                        PointMark(
                            x: .value("Time", point.date),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(by: .value("Series", name))
                        .symbolSize(30)
                        .accessibilityHidden(true)
                    }
                }
            }

            if let selectedRow {
                if mode == .dailyTotals {
                    RuleMark(x: .value("Selected", selectedRow.date, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            callout(for: selectedRow, series: series, dayOnly: true)
                        }
                } else {
                    RuleMark(x: .value("Selected", selectedRow.date))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            callout(for: selectedRow, series: series, dayOnly: false)
                        }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map { Palette.color($0.colorIndex) })
        .chartLegend(.hidden)
        .chartYScale(domain: .automatic(includesZero: mode != .raw))
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartXSelection(value: $selectedDate)
        .modifier(DailyScrolling(enabled: mode == .dailyTotals && analysis.chart.span > 31 * 86_400,
                                 lastDate: analysis.chart.rows.last?.date))
    }

    private var axisFormat: Date.FormatStyle {
        let span = analysis.chart.span
        if analysis.chart.mode != .dailyTotals && span < 36 * 3600 {
            return .dateTime.hour().minute()
        } else if span < 120 * 86_400 {
            return .dateTime.month(.abbreviated).day()
        } else {
            return .dateTime.month(.abbreviated).year()
        }
    }

    private func callout(for row: ChartRow, series: [SeriesDescriptor], dayOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayOnly
                 ? row.date.formatted(date: .abbreviated, time: .omitted)
                 : row.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))
            ForEach(series) { s in
                HStack(spacing: 6) {
                    Circle().fill(Palette.color(s.colorIndex)).frame(width: 8, height: 8)
                    Text(s.name)
                    Spacer(minLength: 12)
                    Text(row.values[s.id].map { ValueFormatter.display(number: $0, type: mode(for: s)) } ?? ValueFormatter.blank)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 240)
    }

    /// Integer fields stay integers in every mode (sums of integers are integers).
    private func mode(for series: SeriesDescriptor) -> FieldType { series.type }

    private func formatted(_ value: Double) -> String {
        ValueFormatter.display(decimal: value)
    }
}

/// Daily Totals shows at most 31 days and scrolls horizontally, opening at the most recent day.
private struct DailyScrolling: ViewModifier {
    let enabled: Bool
    let lastDate: Date?

    func body(content: Content) -> some View {
        if enabled, let lastDate {
            content
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 31 * 86_400)
                .chartScrollPosition(initialX: lastDate.addingTimeInterval(-30 * 86_400))
        } else {
            content
        }
    }
}

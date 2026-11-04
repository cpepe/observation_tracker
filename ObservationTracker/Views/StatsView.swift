import SwiftUI

struct StatsView: View {
    let analysis: ProjectAnalysis
    let rangeTitle: String

    var body: some View {
        if analysis.stats.isEmpty {
            ContentUnavailableView("No Numeric Fields", systemImage: "number",
                                   description: Text("Stats are shown for visible Integer and Decimal fields."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(rangeTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // One column on iPhone, 2–3 on iPad.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(analysis.stats) { StatCard(stats: $0) }
                    }
                }
                .padding()
            }
        }
    }
}

private struct StatCard: View {
    let stats: FieldStats

    private var type: FieldType { stats.series.type }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.color(stats.series.colorIndex))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(stats.series.name)
                    .font(.headline)
                    .foregroundStyle(Palette.color(stats.series.colorIndex))
            }

            if stats.count == 0 {
                Text("No data")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    statRow("Count", stats.count.formatted())
                    statRow("Sum", sumText)
                    statRow("Min", number(stats.min?.value), date: stats.min?.date)
                    statRow("Max", number(stats.max?.value), date: stats.max?.date)
                    statRow("Mean", twoPlaces(stats.mean))
                    statRow("Daily average", twoPlaces(stats.dailyAverage))
                    statRow("Latest", number(stats.latest?.value), date: stats.latest?.date)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var sumText: String {
        if let i = stats.integerSum { return i.formatted() }
        return ValueFormatter.display(number: stats.sum, type: type)
    }

    private func number(_ value: Double?) -> String {
        value.map { ValueFormatter.display(number: $0, type: type) } ?? ValueFormatter.blank
    }

    private func twoPlaces(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? ValueFormatter.blank
    }

    private func statRow(_ label: String, _ value: String, date: Date? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).monospacedDigit()
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .gridColumnAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

import SwiftUI

struct DataTableView: View {
    let analysis: ProjectAnalysis
    /// Visible fields in template order.
    let fields: [FieldDefinition]
    let onEdit: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onDuplicate: (UUID) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum SortKey: Hashable {
        case timestamp
        case field(UUID)
    }

    @State private var sortKey: SortKey = .timestamp
    @State private var ascending = false

    var body: some View {
        VStack(spacing: 0) {
            Text("\(analysis.inRange.count) of \(analysis.totalCount) observations")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 4)

            if analysis.inRange.isEmpty {
                ContentUnavailableView(
                    analysis.totalCount == 0 ? "No Observations" : "No Observations in This Range",
                    systemImage: "tablecells"
                )
            } else if horizontalSizeClass == .regular {
                regularTable
            } else {
                compactList
            }
        }
    }

    // MARK: iPhone

    private var compactList: some View {
        List {
            ForEach(analysis.sections) { section in
                Section(section.id.daySectionTitle) {
                    ForEach(section.observations) { obs in
                        row(obs) { CompactRow(observation: obs, fields: fields) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: iPad

    private var regularTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sortHeader("Time", key: .timestamp, alignment: .leading)
                    .frame(width: 180, alignment: .leading)
                ForEach(fields) { field in
                    sortHeader(field.name, key: .field(field.id), alignment: field.type.isNumeric ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: field.type.isNumeric ? .trailing : .leading)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))

            List {
                if sortKey == .timestamp {
                    let sections = ascending ? analysis.sections.reversed().map { DaySection(id: $0.id, observations: $0.observations.reversed()) } : analysis.sections
                    ForEach(sections) { section in
                        Section(section.id.daySectionTitle) {
                            ForEach(section.observations) { obs in
                                row(obs) { TableRow(observation: obs, fields: fields) }
                            }
                        }
                    }
                } else {
                    ForEach(sortedByField) { obs in
                        row(obs) { TableRow(observation: obs, fields: fields, showsDate: true) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func sortHeader(_ title: String, key: SortKey, alignment: HorizontalAlignment) -> some View {
        Button {
            if sortKey == key {
                ascending.toggle()
            } else {
                sortKey = key
                ascending = key != .timestamp ? true : false
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if sortKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(sortKey == key ? (ascending ? "Ascending" : "Descending") : "")
    }

    /// Sorted by a field's value; blanks always sort last, ties by timestamp (newest first).
    private var sortedByField: [ObservationSnapshot] {
        guard case .field(let id) = sortKey, let field = fields.first(where: { $0.id == id }) else { return analysis.inRange }
        return analysis.inRange.sorted { a, b in
            switch (a.values[id], b.values[id]) {
            case (nil, nil): return a.timestamp > b.timestamp
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?):
                if x == y { return a.timestamp > b.timestamp }
                if field.type.isNumeric {
                    return ascending ? (x.doubleValue ?? 0) < (y.doubleValue ?? 0) : (x.doubleValue ?? 0) > (y.doubleValue ?? 0)
                }
                let cmp = ValueFormatter.display(x).localizedStandardCompare(ValueFormatter.display(y))
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    // MARK: Row actions

    private func row<Content: View>(_ obs: ObservationSnapshot, @ViewBuilder content: () -> Content) -> some View {
        Button {
            onEdit(obs.id)
        } label: {
            content().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDelete(obs.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { onEdit(obs.id) } label: { Label("Edit", systemImage: "pencil") }
            Button { onDuplicate(obs.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { onDelete(obs.id) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityHint("Opens the observation for editing")
    }
}

private struct CompactRow: View {
    let observation: ObservationSnapshot
    let fields: [FieldDefinition]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(observation.timestamp, format: .dateTime.hour().minute())
                .font(.headline)
            FlowLayout(spacing: 12, lineSpacing: 2) {
                ForEach(fields) { field in
                    HStack(spacing: 4) {
                        Text("\(field.name):").foregroundStyle(.secondary)
                        Text(ValueFormatter.display(observation.values[field.id]))
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct TableRow: View {
    let observation: ObservationSnapshot
    let fields: [FieldDefinition]
    var showsDate = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if showsDate {
                    Text(observation.timestamp, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                } else {
                    Text(observation.timestamp, format: .dateTime.hour().minute())
                }
            }
            .frame(width: 180, alignment: .leading)

            ForEach(fields) { field in
                Text(ValueFormatter.display(observation.values[field.id]))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: field.type.isNumeric ? .trailing : .leading)
                    .accessibilityLabel("\(field.name), \(ValueFormatter.display(observation.values[field.id]))")
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Wraps `name: value` pairs onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let width = min(size.width, bounds.width)
            if x > bounds.minX && x + width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

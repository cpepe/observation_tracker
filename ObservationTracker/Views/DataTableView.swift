import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DataTableView: View {
    let analysis: ProjectAnalysis
    /// Visible fields in template order.
    let fields: [FieldDefinition]
    let onAdd: (Date, [UUID: FieldValue]) -> Void
    let onEdit: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onDuplicate: (UUID) -> Void

    enum SortKey: Hashable {
        case timestamp
        case field(UUID)
    }

    @State private var sortKey: SortKey = .timestamp
    @State private var ascending = false

    // Top input row state for adding a new observation
    @State private var inputTexts: [UUID: String] = [:]
    @State private var newTimestamp: Date = .now
    @State private var isLive: Bool = true
    @State private var showingDatePickerModal = false
    @FocusState private var focusedField: UUID?

    private let minDateWidth: CGFloat = 150
    private let minActionWidth: CGFloat = 44
    private let minFieldWidth: CGFloat = 100
    private let rowHeight: CGFloat = 38
    private let headerHeight: CGFloat = 32
    private let inputRowHeight: CGFloat = 44

    // MARK: - Validation & Input Parsing

    private func parsed(_ field: FieldDefinition) -> Result<FieldValue?, ValueFormatter.InputError> {
        ValueFormatter.parseInput(inputTexts[field.id] ?? "", type: field.type)
    }

    private func fieldError(_ field: FieldDefinition) -> String? {
        guard let text = inputTexts[field.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if case .failure(let error) = parsed(field) {
            return error.message
        }
        return nil
    }

    private var activeError: String? {
        for field in fields {
            if let err = fieldError(field) {
                return "\(field.name): \(err)"
            }
        }
        return nil
    }

    private var hasErrors: Bool {
        fields.contains { fieldError($0) != nil }
    }

    private var hasAnyValue: Bool {
        fields.contains {
            guard let text = inputTexts[$0.id] else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canAdd: Bool {
        hasAnyValue && !hasErrors
    }

    // MARK: - Focus Management

    private var nextFieldID: UUID? {
        guard let current = focusedField, let idx = fields.firstIndex(where: { $0.id == current }), idx + 1 < fields.count else {
            return nil
        }
        return fields[idx + 1].id
    }

    private var previousFieldID: UUID? {
        guard let current = focusedField, let idx = fields.firstIndex(where: { $0.id == current }), idx > 0 else {
            return nil
        }
        return fields[idx - 1].id
    }

    private func focusNext() {
        focusedField = nextFieldID
    }

    private func focusPrevious() {
        focusedField = previousFieldID
    }

    // MARK: - Commit Observation

    private func commitNewObservation() {
        guard canAdd else { return }
        var values: [UUID: FieldValue] = [:]
        for field in fields {
            if let text = inputTexts[field.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if case .success(let val?) = parsed(field) {
                    values[field.id] = val
                }
            }
        }
        let time = (isLive ? Date.now : newTimestamp).truncatedToSecond
        onAdd(time, values)

        inputTexts.removeAll()
        isLive = true
        newTimestamp = .now
        focusedField = nil

        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: - Sorting

    private var sortedObservations: [ObservationSnapshot] {
        switch sortKey {
        case .timestamp:
            return ascending ? analysis.inRange.reversed() : analysis.inRange
        case .field(let id):
            guard let field = fields.first(where: { $0.id == id }) else { return analysis.inRange }
            return analysis.inRange.sorted { a, b in
                switch (a.values[id], b.values[id]) {
                case (nil, nil):
                    return a.timestamp > b.timestamp
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let x?, let y?):
                    if x == y { return a.timestamp > b.timestamp }
                    if field.type.isNumeric {
                        let dx = x.doubleValue ?? 0
                        let dy = y.doubleValue ?? 0
                        return ascending ? dx < dy : dx > dy
                    }
                    let cmp = ValueFormatter.display(x).localizedStandardCompare(ValueFormatter.display(y))
                    return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

            GeometryReader { proxy in
                let availableWidth = proxy.size.width
                let fieldCount = max(1, fields.count)
                let minTotalWidth = minDateWidth + minActionWidth + (CGFloat(fieldCount) * minFieldWidth)

                let tableWidth = max(availableWidth, minTotalWidth)
                let extraWidth = max(0, availableWidth - minDateWidth - minActionWidth)
                let fieldWidth = tableWidth > minTotalWidth ? (extraWidth / CGFloat(fieldCount)) : minFieldWidth
                let dateWidth = minDateWidth
                let actionWidth = minActionWidth

                ScrollView(.horizontal, showsIndicators: tableWidth > availableWidth) {
                    VStack(spacing: 0) {
                        // Sticky Header
                        headerRow(dateWidth: dateWidth, fieldWidth: fieldWidth, actionWidth: actionWidth)
                        Divider()

                        // Sticky Top Input Row
                        inputRow(dateWidth: dateWidth, fieldWidth: fieldWidth, actionWidth: actionWidth)
                        Divider()

                        if let err = activeError {
                            errorBanner(err, width: tableWidth)
                            Divider()
                        }

                        // Scrollable observation rows
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                if sortedObservations.isEmpty {
                                    emptyState(tableWidth: tableWidth)
                                } else {
                                    ForEach(Array(sortedObservations.enumerated()), id: \.element.id) { index, obs in
                                        observationRow(
                                            obs: obs,
                                            index: index,
                                            dateWidth: dateWidth,
                                            fieldWidth: fieldWidth,
                                            actionWidth: actionWidth
                                        )
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(width: tableWidth, height: proxy.size.height)
                }
            }
        }
        .toolbar { keyboardToolbar }
        .sheet(isPresented: $showingDatePickerModal) {
            ObservationTimePickerModal(
                timestamp: $newTimestamp,
                isLive: $isLive
            )
        }
    }

    // MARK: - Subviews

    private var summaryBar: some View {
        HStack {
            Text("\(analysis.inRange.count) of \(analysis.totalCount) observations")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func headerRow(dateWidth: CGFloat, fieldWidth: CGFloat, actionWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            sortHeader("Date & Time", key: .timestamp, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(width: dateWidth, alignment: .leading)

            ForEach(fields) { field in
                sortHeader(field.name, key: .field(field.id), alignment: field.type.isNumeric ? .trailing : .leading)
                    .padding(.horizontal, 8)
                    .frame(width: fieldWidth, alignment: field.type.isNumeric ? .trailing : .leading)
            }

            Color.clear
                .frame(width: actionWidth)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: headerHeight)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func sortHeader(_ title: String, key: SortKey, alignment: Alignment) -> some View {
        Button {
            if sortKey == key {
                ascending.toggle()
            } else {
                sortKey = key
                ascending = (key == .timestamp) ? false : true
            }
        } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                if sortKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(sortKey == key ? (ascending ? "Ascending" : "Descending") : "")
    }

    private func inputRow(dateWidth: CGFloat, fieldWidth: CGFloat, actionWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Date / Time text button (opens modal on tap)
            HStack(spacing: 4) {
                Button {
                    showingDatePickerModal = true
                } label: {
                    HStack(spacing: 4) {
                        TimelineView(.everyMinute) { context in
                            let date = isLive ? context.date : newTimestamp
                            Text(date.formatted(date: .numeric, time: .shortened))
                                .font(.subheadline)
                                .monospacedDigit()
                                .lineLimit(1)
                                .foregroundStyle(isLive ? .primary : Color.accentColor)
                        }

                        Image(systemName: isLive ? "clock" : "clock.fill")
                            .font(.caption2)
                            .foregroundStyle(isLive ? .secondary : Color.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isLive ? Color(uiColor: .tertiarySystemFill) : Color.accentColor.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isLive ? Color.clear : Color.accentColor.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change observation date and time")

                if !isLive {
                    Button {
                        isLive = true
                        newTimestamp = .now
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset time to now")
                }
            }
            .padding(.horizontal, 6)
            .frame(width: dateWidth, alignment: .leading)

            // Input fields for each column
            ForEach(fields) { field in
                TextField(
                    field.type == .integer ? "Integer" : (field.type == .decimal ? "Decimal" : "Text"),
                    text: Binding(
                        get: { inputTexts[field.id] ?? "" },
                        set: { inputTexts[field.id] = $0 }
                    )
                )
                .font(.subheadline)
                .monospacedDigit(field.type.isNumeric)
                .multilineTextAlignment(field.type.isNumeric ? .trailing : .leading)
                .keyboardType(field.type == .integer ? .numberPad : (field.type == .decimal ? .decimalPad : .default))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(fieldError(field) != nil ? Color.red.opacity(0.12) : Color(uiColor: .tertiarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(fieldError(field) != nil ? Color.red : Color.clear, lineWidth: 1)
                )
                .focused($focusedField, equals: field.id)
                .onSubmit {
                    commitNewObservation()
                }
                .padding(.horizontal, 4)
                .frame(width: fieldWidth)
            }

            // Action button (Add)
            Button(action: commitNewObservation) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(canAdd ? Color.accentColor : Color.secondary.opacity(0.3))
                    .clipShape(Circle())
            }
            .disabled(!canAdd)
            .frame(width: actionWidth, alignment: .center)
            .accessibilityLabel("Add observation")
        }
        .frame(height: inputRowHeight)
        .background(Color(uiColor: .systemBackground))
    }

    private func errorBanner(_ message: String, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        .background(Color.red.opacity(0.08))
    }

    private func observationRow(
        obs: ObservationSnapshot,
        index: Int,
        dateWidth: CGFloat,
        fieldWidth: CGFloat,
        actionWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            // Timestamp
            Text(obs.timestamp.formatted(date: .numeric, time: .shortened))
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: dateWidth, alignment: .leading)

            // Values
            ForEach(fields) { field in
                Text(ValueFormatter.display(obs.values[field.id]))
                    .font(.subheadline)
                    .monospacedDigit(field.type.isNumeric)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: fieldWidth, alignment: field.type.isNumeric ? .trailing : .leading)
            }

            // Actions menu
            Menu {
                Button { onEdit(obs.id) } label: { Label("Edit", systemImage: "pencil") }
                Button { onDuplicate(obs.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { onDelete(obs.id) } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: actionWidth, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Observation actions")
        }
        .frame(height: rowHeight)
        .background(index % 2 == 1 ? Color(uiColor: .secondarySystemBackground).opacity(0.35) : Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit(obs.id)
        }
        .contextMenu {
            Button { onEdit(obs.id) } label: { Label("Edit", systemImage: "pencil") }
            Button { onDuplicate(obs.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { onDelete(obs.id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func emptyState(tableWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(analysis.totalCount == 0 ? "No Observations Yet" : "No Observations in This Range")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(analysis.totalCount == 0 ? "Enter values in the row above to add your first observation." : "Adjust the date range above to see observations.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 32)
        .frame(width: tableWidth)
    }

    @ToolbarContentBuilder
    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Button("Previous") {
                focusPrevious()
            }
            .disabled(previousFieldID == nil)

            Button("Next") {
                focusNext()
            }
            .disabled(nextFieldID == nil)

            Spacer()

            Button("Done") {
                focusedField = nil
            }

            Button("Add") {
                commitNewObservation()
            }
            .bold()
            .disabled(!canAdd)
        }
    }
}

// MARK: - Date & Time Picker Modal

struct ObservationTimePickerModal: View {
    @Binding var timestamp: Date
    @Binding var isLive: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date
    @State private var selectedLive: Bool

    init(timestamp: Binding<Date>, isLive: Binding<Bool>) {
        _timestamp = timestamp
        _isLive = isLive
        _selectedDate = State(initialValue: isLive.wrappedValue ? .now : timestamp.wrappedValue)
        _selectedLive = State(initialValue: isLive.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Status and quick reset
                HStack {
                    Label(
                        selectedLive ? "Using Current Time (Live)" : "Custom Timestamp",
                        systemImage: selectedLive ? "clock.arrow.2.circlepath" : "clock"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selectedLive ? Color.accentColor : .secondary)

                    Spacer()

                    if !selectedLive {
                        Button {
                            selectedDate = .now
                            selectedLive = true
                        } label: {
                            Label("Set to Now", systemImage: "arrow.counterclockwise")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Divider()

                DatePicker(
                    "Select Date and Time",
                    selection: Binding(
                        get: { selectedDate },
                        set: {
                            selectedDate = $0
                            selectedLive = false
                        }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal)

                if !selectedLive && selectedDate > Date.now.addingTimeInterval(60) {
                    Label("This time is in the future", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Observation Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        timestamp = selectedDate
                        isLive = selectedLive
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension View {
    @ViewBuilder
    func monospacedDigit(_ enabled: Bool) -> some View {
        if enabled {
            self.monospacedDigit()
        } else {
            self
        }
    }
}

import SwiftData
import SwiftUI

/// Entry and edit form for one observation.
struct ObservationFormView: View {
    let project: Project
    let request: FormRequest
    var onDeleted: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Visible fields in template order.
    private let fields: [FieldDefinition]
    /// Values the form doesn't show (hidden fields) are carried through unchanged.
    private let baseValues: [UUID: FieldValue]

    @State private var texts: [UUID: String]
    /// While live, the timestamp tracks the clock and is taken at the moment of Save.
    @State private var isLive: Bool
    @State private var timestamp: Date
    @State private var insertedRecord: ObservationRecord?
    @State private var saveError: String?
    @FocusState private var focusedField: UUID?

    init(project: Project, request: FormRequest, onDeleted: @escaping () -> Void = {}) {
        self.project = project
        self.request = request
        self.onDeleted = onDeleted
        let fields = project.visibleFields
        self.fields = fields

        let values: [UUID: FieldValue]
        switch request.kind {
        case .new(let prefill):
            values = prefill
            _isLive = State(initialValue: true)
            _timestamp = State(initialValue: .now)
        case .edit(let record):
            values = record.values
            _isLive = State(initialValue: false)       // edits start frozen at the stored time
            _timestamp = State(initialValue: record.timestamp)
        }
        baseValues = values
        var texts: [UUID: String] = [:]
        for field in fields {
            if let v = values[field.id] { texts[field.id] = ValueFormatter.editingText(v) }
        }
        _texts = State(initialValue: texts)
    }

    private var editingRecord: ObservationRecord? {
        if case .edit(let record) = request.kind { return record }
        return nil
    }

    // MARK: Validation

    private func parsed(_ field: FieldDefinition) -> Result<FieldValue?, ValueFormatter.InputError> {
        ValueFormatter.parseInput(texts[field.id] ?? "", type: field.type)
    }

    private var hasErrors: Bool {
        fields.contains { if case .failure = parsed($0) { return true } else { return false } }
    }

    private var hasAnyValue: Bool {
        fields.contains { if case .success(.some) = parsed($0) { return true } else { return false } }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                timestampSection

                Section("Values") {
                    ForEach(fields) { field in
                        fieldRow(field)
                    }
                }

                if editingRecord != nil {
                    Section {
                        Button("Delete Observation", role: .destructive, action: delete)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(editingRecord == nil ? "New Observation" : "Edit Observation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(hasErrors || !hasAnyValue)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Next", action: focusNext)
                        .disabled(nextField == nil)
                    Button("Done") { focusedField = nil }
                }
            }
            .task {
                // The first numeric field gets focus immediately for fast entry.
                guard editingRecord == nil else { return }
                try? await Task.sleep(for: .milliseconds(450))
                focusedField = fields.first(where: { $0.type.isNumeric })?.id
            }
            .alert(
                "Couldn't Save",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(saveError ?? "") }
            )
        }
    }

    private var timestampSection: some View {
        Section {
            TimelineView(.everyMinute) { context in
                let shown = isLive ? context.date : timestamp
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        DatePicker(
                            "Time",
                            selection: Binding(get: { shown }, set: { timestamp = $0; isLive = false }),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        if !isLive {
                            Button("Now") { isLive = true }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Uses the current time when you save")
                        }
                    }
                    if !isLive && timestamp > context.date.addingTimeInterval(60) {
                        Label("This time is in the future", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Timestamp")
        } footer: {
            if isLive { Text("Uses the current time when you save.") }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: FieldDefinition) -> some View {
        let binding = Binding(get: { texts[field.id] ?? "" }, set: { texts[field.id] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            if field.type == .text {
                Text(field.name).font(.subheadline).foregroundStyle(.secondary)
                TextField("Text", text: binding, axis: .vertical)
                    .focused($focusedField, equals: field.id)
                    .accessibilityLabel(field.name)
            } else {
                LabeledContent(field.name) {
                    TextField(field.type == .integer ? "Whole number" : "Number", text: binding)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(field.type == .integer ? .numberPad : .decimalPad)
                        .focused($focusedField, equals: field.id)
                        .accessibilityLabel(field.name)
                }
            }
            if case .failure(let error) = parsed(field) {
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var nextField: UUID? {
        guard let current = focusedField, let i = fields.firstIndex(where: { $0.id == current }), i + 1 < fields.count else {
            return nil
        }
        return fields[i + 1].id
    }

    private func focusNext() {
        focusedField = nextField
    }

    // MARK: Actions

    private func save() {
        var values = baseValues
        for field in fields {
            switch parsed(field) {
            case .success(let value?): values[field.id] = value
            case .success(nil): values.removeValue(forKey: field.id)
            case .failure: return
            }
        }
        let time = (isLive ? Date.now : timestamp).truncatedToSecond

        if let record = editingRecord {
            record.timestamp = time
            record.values = values
            record.modifiedAt = .now
        } else if let record = insertedRecord {
            // A previous save attempt failed; update the same record rather than inserting again.
            record.timestamp = time
            record.values = values
            record.modifiedAt = .now
        } else {
            let record = ObservationRecord(timestamp: time, values: values)
            modelContext.insert(record)
            record.project = project
            insertedRecord = record
        }
        project.updatedAt = .now

        do {
            try modelContext.save()
            dismiss()
        } catch {
            // Leave the form open so nothing typed is lost.
            saveError = "The observation couldn't be saved. \(error.localizedDescription)"
        }
    }

    private func cancel() {
        if let insertedRecord {
            modelContext.delete(insertedRecord)
        }
        dismiss()
    }

    private func delete() {
        guard let record = editingRecord else { return }
        modelContext.delete(record)
        project.updatedAt = .now
        try? modelContext.save()
        dismiss()
        onDeleted()
    }
}

import SwiftData
import SwiftUI

/// Preview for a parsed CSV, importing either into an existing project
/// (matching columns to fields by name) or as a new project.
struct ImportPreviewView: View {
    enum Mode {
        case existing(Project)
        case newProject
    }

    struct ColumnDraft: Identifiable {
        let column: Int
        let header: String
        let info: ColumnInfo
        /// Existing-project mode: the field this column maps to.
        let matchedField: FieldDefinition?
        var include: Bool
        var name: String
        var type: FieldType
        let newFieldID = UUID()

        var id: Int { column }
    }

    let csv: LoadedCSV
    let mode: Mode
    /// Called after a successful import with the created project (new-project mode) or nil.
    let onComplete: (Project?) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allProjects: [Project]

    @State private var projectName: String
    @State private var timestampColumn: Int?
    @State private var drafts: [ColumnDraft] = []
    @State private var existingSnapshots: [ObservationSnapshot] = []
    @State private var evaluation: ImportEvaluation?
    @State private var isPreparing = true
    @State private var saveError: String?

    init(csv: LoadedCSV, mode: Mode, onComplete: @escaping (Project?) -> Void) {
        self.csv = csv
        self.mode = mode
        self.onComplete = onComplete
        _projectName = State(initialValue: csv.baseName)
        _timestampColumn = State(initialValue: CSVImportAnalyzer.timestampColumn(in: csv.table.header))
    }

    private var existingProject: Project? {
        if case .existing(let p) = mode { return p }
        return nil
    }

    // MARK: Targets and validation

    private var activeDrafts: [ColumnDraft] {
        drafts.filter { $0.column != timestampColumn }
    }

    private var targets: [ImportTarget] {
        activeDrafts.compactMap { d in
            if let field = d.matchedField { return ImportTarget(column: d.column, fieldID: field.id, type: field.type) }
            return d.include ? ImportTarget(column: d.column, fieldID: d.newFieldID, type: d.type) : nil
        }
    }

    private func nameError(_ draft: ColumnDraft) -> String? {
        guard draft.matchedField == nil, draft.include else { return nil }
        var others = activeDrafts.filter { $0.id != draft.id && $0.matchedField == nil && $0.include }.map(\.name)
        others += existingProject?.fields.map(\.name) ?? []
        return FieldNameRules.validate(draft.name, otherNames: others)
    }

    private var projectNameError: String? {
        guard existingProject == nil else { return nil }
        let n = FieldNameRules.normalize(projectName)
        if n.isEmpty { return "Enter a project name." }
        if allProjects.contains(where: { FieldNameRules.normalize($0.name) == n }) { return "Another project already uses this name." }
        return nil
    }

    private var hasNumericTarget: Bool {
        targets.contains { $0.type.isNumeric }
    }

    private var canImport: Bool {
        guard timestampColumn != nil, let evaluation, !isPreparing else { return false }
        if activeDrafts.contains(where: { nameError($0) != nil }) { return false }
        if existingProject == nil {
            return projectNameError == nil && hasNumericTarget
        }
        return !evaluation.rows.isEmpty
    }

    private struct EvaluationKey: Hashable {
        let timestampColumn: Int?
        let targets: [ImportTarget]
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    LabeledContent("Name", value: csv.fileName)
                    LabeledContent("Rows", value: csv.table.rows.count.formatted())
                    LabeledContent("Delimiter", value: csv.table.delimiterName)
                }

                if existingProject == nil {
                    Section {
                        TextField("Project name", text: $projectName)
                    } header: {
                        Text("Project")
                    } footer: {
                        if let projectNameError { Text(projectNameError).foregroundStyle(.red) }
                    }
                }

                Section {
                    Picker("Timestamp column", selection: $timestampColumn) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(Array(csv.table.header.enumerated()), id: \.offset) { index, name in
                            Text(name.isEmpty ? "Column \(index + 1)" : name).tag(Int?.some(index))
                        }
                    }
                } footer: {
                    if timestampColumn == nil {
                        Text("No column is named timestamp, datetime, date or time. Pick the column that holds each row's time.")
                            .foregroundStyle(.red)
                    }
                }

                if isPreparing {
                    Section { ProgressView("Analyzing columns…") }
                } else {
                    columnsSection
                    if let project = existingProject { missingFieldsSection(project) }
                    summarySection
                }
            }
            .navigationTitle(existingProject == nil ? "New Project from CSV" : "Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: commit)
                        .disabled(!canImport)
                }
            }
            .task { await prepare() }
            .task(id: EvaluationKey(timestampColumn: timestampColumn, targets: targets)) { await evaluate() }
            .alert(
                "Import Failed",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(saveError ?? "") }
            )
        }
        .interactiveDismissDisabled()
    }

    private var confirmTitle: String {
        let n = evaluation?.rows.count ?? 0
        return existingProject == nil ? "Create Project" : "Import \(n) Row\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var columnsSection: some View {
        Section {
            ForEach($drafts) { $draft in
                if draft.column != timestampColumn {
                    columnRow($draft)
                }
            }
        } header: {
            Text("Columns")
        } footer: {
            if existingProject == nil && !hasNumericTarget {
                Text("Include at least one Integer or Decimal column so there's something to chart.")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func columnRow(_ draft: Binding<ColumnDraft>) -> some View {
        let d = draft.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            if let field = d.matchedField {
                LabeledContent {
                    Text("\(field.name) · \(field.type.title)")
                } label: {
                    Label(d.header, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if existingProject != nil {
                Text(d.header.isEmpty ? "Column \(d.column + 1)" : d.header).font(.headline)
                Picker("Action", selection: draft.include) {
                    Text("Ignore").tag(false)
                    Text("Add as New Field").tag(true)
                }
                .pickerStyle(.segmented)
                if d.include {
                    newFieldEditor(draft)
                }
            } else {
                Toggle(isOn: draft.include) {
                    Text(d.header.isEmpty ? "Column \(d.column + 1)" : d.header).font(.headline)
                }
                if d.include {
                    newFieldEditor(draft)
                }
            }
            if let error = nameError(d) {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func newFieldEditor(_ draft: Binding<ColumnDraft>) -> some View {
        HStack {
            TextField("Field name", text: draft.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Type", selection: draft.type) {
                ForEach(draft.wrappedValue.info.allowedTypes) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private func missingFieldsSection(_ project: Project) -> some View {
        let matched = Set(drafts.compactMap { $0.column == timestampColumn ? nil : $0.matchedField?.id })
        let missing = project.fields.filter { !matched.contains($0.id) }
        if !missing.isEmpty {
            Section {
                ForEach(missing) { Text($0.name) }
            } header: {
                Text("Fields Not in File")
            } footer: {
                Text("These fields will be left blank on imported rows.")
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if timestampColumn != nil {
            Section("Summary") {
                if let evaluation {
                    LabeledContent("Valid rows", value: evaluation.rows.count.formatted())
                    LabeledContent("Duplicates to skip", value: evaluation.duplicateCount.formatted())
                    LabeledContent("Errors (skipped)", value: evaluation.errors.count.formatted())
                } else {
                    ProgressView("Checking rows…")
                }
            }
            if let errors = evaluation?.errors, !errors.isEmpty {
                Section("Errors") {
                    ForEach(errors.prefix(200)) { error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Row \(error.row)").font(.subheadline.weight(.semibold))
                            Text(error.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if errors.count > 200 {
                        Text("and \(errors.count - 200) more").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Work

    private func prepare() async {
        let table = csv.table
        let fields = existingProject?.fields ?? []
        existingSnapshots = existingProject?.sortedSnapshots() ?? []
        let isNew = existingProject == nil

        let infos = await Task.detached(priority: .userInitiated) {
            (0..<table.header.count).map { CSVImportAnalyzer.columnInfo(table: table, column: $0) }
        }.value

        var claimed = Set<UUID>()
        drafts = table.header.enumerated().map { index, header in
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            var match: FieldDefinition?
            if let field = fields.first(where: { FieldNameRules.normalize($0.name) == FieldNameRules.normalize(trimmed) }),
               !claimed.contains(field.id) {
                match = field
                claimed.insert(field.id)
            }
            return ColumnDraft(
                column: index,
                header: trimmed,
                info: infos[index],
                matchedField: match,
                include: isNew,
                name: trimmed.isEmpty ? "Column \(index + 1)" : trimmed,
                type: infos[index].inferredType
            )
        }
        isPreparing = false
    }

    private func evaluate() async {
        guard !isPreparing, let timestampColumn else {
            evaluation = nil
            return
        }
        evaluation = nil
        let table = csv.table
        let targets = targets
        let existing = existingSnapshots
        let work = Task.detached(priority: .userInitiated) {
            try CSVImportAnalyzer.evaluate(table: table, timestampColumn: timestampColumn, targets: targets, existing: existing)
        }
        let result = await withTaskCancellationHandler {
            try? await work.value
        } onCancel: {
            work.cancel()
        }
        if !Task.isCancelled, let result { evaluation = result }
    }

    private func commit() {
        guard let evaluation else { return }
        let newFields = activeDrafts
            .filter { $0.matchedField == nil && $0.include }
            .map { FieldDefinition(id: $0.newFieldID, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), type: $0.type) }

        if let project = existingProject {
            // One transaction, one undo group: the Undo Import banner reverts all of it.
            modelContext.undoManager?.setActionName("Import")
            if !newFields.isEmpty { project.fields += newFields }
            let records = evaluation.rows.map { ObservationRecord(timestamp: $0.timestamp, values: $0.values) }
            for record in records { modelContext.insert(record) }
            project.observations.append(contentsOf: records)
            project.updatedAt = .now
            do {
                try modelContext.save()
                dismiss()
                onComplete(nil)
            } catch {
                modelContext.rollback()
                saveError = error.localizedDescription
            }
        } else {
            let project = Project(
                name: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
                fields: newFields
            )
            modelContext.withoutUndo {
                modelContext.insert(project)
                let records = evaluation.rows.map { ObservationRecord(timestamp: $0.timestamp, values: $0.values) }
                for record in records { modelContext.insert(record) }
                project.observations.append(contentsOf: records)
            }
            do {
                try modelContext.save()
                dismiss()
                onComplete(project)
            } catch {
                modelContext.rollback()
                saveError = error.localizedDescription
            }
        }
    }
}

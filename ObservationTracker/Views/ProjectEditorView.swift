import SwiftData
import SwiftUI

/// Creates a project, or edits an existing project's name, notes and template.
/// Existing fields can be renamed, reordered and hidden, never deleted or retyped.
struct ProjectEditorView: View {
    enum Mode {
        case create
        case edit(Project)
    }

    struct DraftField: Identifiable, Equatable {
        let id: UUID
        var name: String
        var type: FieldType
        var isHidden: Bool
        let isExisting: Bool
    }

    let mode: Mode
    var onCreated: (Project) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allProjects: [Project]

    @State private var name: String
    @State private var notes: String
    @State private var drafts: [DraftField]
    @State private var showingImporter = false
    @State private var loadedCSV: LoadedCSV?
    @State private var saveError: String?

    init(mode: Mode, onCreated: @escaping (Project) -> Void = { _ in }) {
        self.mode = mode
        self.onCreated = onCreated
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _notes = State(initialValue: "")
            _drafts = State(initialValue: [DraftField(id: UUID(), name: "", type: .decimal, isHidden: false, isExisting: false)])
        case .edit(let project):
            _name = State(initialValue: project.name)
            _notes = State(initialValue: project.notes)
            _drafts = State(initialValue: project.fields.map {
                DraftField(id: $0.id, name: $0.name, type: $0.type, isHidden: $0.isHidden, isExisting: true)
            })
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var editingProjectID: UUID? {
        if case .edit(let p) = mode { return p.id }
        return nil
    }

    // MARK: Validation

    private var nameError: String? {
        let n = FieldNameRules.normalize(name)
        if n.isEmpty { return "Enter a project name." }
        let clash = allProjects.contains { $0.id != editingProjectID && FieldNameRules.normalize($0.name) == n }
        return clash ? "Another project already uses this name." : nil
    }

    private func fieldError(_ draft: DraftField) -> String? {
        FieldNameRules.validate(draft.name, otherNames: drafts.filter { $0.id != draft.id }.map(\.name))
    }

    private var visibleNumericCount: Int {
        drafts.filter { $0.type.isNumeric && !$0.isHidden }.count
    }

    private var canSave: Bool {
        nameError == nil && visibleNumericCount > 0 && drafts.allSatisfy { fieldError($0) == nil }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("Project")
                } footer: {
                    if let nameError, !name.isEmpty { Text(nameError).foregroundStyle(.red) }
                }

                Section {
                    ForEach($drafts) { $draft in
                        fieldRow($draft)
                            .deleteDisabled(draft.isExisting)
                    }
                    .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { drafts.remove(atOffsets: $0) }

                    Button {
                        drafts.append(DraftField(id: UUID(), name: "", type: .decimal, isHidden: false, isExisting: false))
                    } label: {
                        Label("Add Field", systemImage: "plus.circle")
                    }
                } header: {
                    HStack {
                        Text("Fields")
                        Spacer()
                        EditButton().font(.footnote)
                    }
                } footer: {
                    if visibleNumericCount == 0 {
                        Text(isCreating
                             ? "Add at least one Integer or Decimal field so there's something to chart."
                             : "At least one Integer or Decimal field must stay visible.")
                            .foregroundStyle(.red)
                    } else if !isCreating {
                        Text("A field's type can't change after it's created. Fields can't be deleted; hide them instead. Hidden fields keep their data and are still exported.")
                    } else {
                        Text("Field types can't be changed after the project is created.")
                    }
                }

                if isCreating {
                    Section {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import from CSV…", systemImage: "square.and.arrow.down")
                        }
                    } footer: {
                        Text("Builds the project's fields and observations from a CSV file.")
                    }
                }
            }
            .navigationTitle(isCreating ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .csvImportFlow(isPresented: $showingImporter) { loadedCSV = $0 }
            .sheet(item: $loadedCSV) { csv in
                ImportPreviewView(csv: csv, mode: .newProject) { project in
                    if let project {
                        onCreated(project)
                        dismiss()
                    }
                }
            }
            .alert(
                "Couldn't Save",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(saveError ?? "") }
            )
        }
    }

    @ViewBuilder
    private func fieldRow(_ draft: Binding<DraftField>) -> some View {
        let d = draft.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Field name", text: draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Field name")
                if d.isExisting {
                    Text(d.type.title)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Type \(d.type.title), can't be changed")
                } else {
                    Picker("Type", selection: draft.type) {
                        ForEach(FieldType.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if d.isExisting {
                let isLastVisibleNumeric = !d.isHidden && d.type.isNumeric && visibleNumericCount == 1
                Toggle("Hidden", isOn: draft.isHidden)
                    .disabled(isLastVisibleNumeric)
                    .font(.subheadline)
            }
            if !d.name.isEmpty, let error = fieldError(d) {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func save() {
        let fields = drafts.map {
            FieldDefinition(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), type: $0.type, isHidden: $0.isHidden)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create:
            let project = Project(name: trimmedName, notes: trimmedNotes, fields: fields)
            modelContext.withoutUndo { modelContext.insert(project) }
            do {
                try modelContext.save()
                onCreated(project)
                dismiss()
            } catch {
                modelContext.withoutUndo { modelContext.delete(project) }
                saveError = error.localizedDescription
            }
        case .edit(let project):
            modelContext.withoutUndo {
                project.name = trimmedName
                project.notes = trimmedNotes
                project.fields = fields
                project.updatedAt = .now
            }
            do {
                try modelContext.save()
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

import SwiftData
import SwiftUI

struct ProjectListView: View {
    let projects: [Project]
    @Binding var selection: UUID?

    @Environment(\.modelContext) private var modelContext
    @State private var showingNewProject = false
    @State private var pendingDelete: Project?
    @State private var shareItem: ShareItem?
    @State private var exportError: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(projects) { project in
                NavigationLink(value: project.id) {
                    ProjectRow(project: project)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        pendingDelete = project
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)

                    Button {
                        export(project)
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                }
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("A project is one thing you measure over time. You choose the fields each observation records, then log readings and see them charted.")
                } actions: {
                    Button("New Project") { showingNewProject = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewProject) {
            ProjectEditorView(mode: .create) { project in
                selection = project.id
            }
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { project in
            Button("Export CSV First") { export(project) }
            Button("Delete", role: .destructive) { delete(project) }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            let n = project.observations.count
            Text("“\(project.name)” and its \(n) observation\(n == 1 ? "" : "s") will be permanently deleted. This can't be undone.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
                .presentationDetents([.medium, .large])
        }
        .alert(
            "Export Failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(exportError ?? "") }
        )
    }

    private func export(_ project: Project) {
        let id = project.persistentModelID
        let container = modelContext.container
        Task {
            do {
                try modelContext.save()
                shareItem = ShareItem(url: try await CSVExportService.writeFile(projectID: id, container: container))
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func delete(_ project: Project) {
        if selection == project.id { selection = nil }
        modelContext.withoutUndo {
            modelContext.delete(project)
        }
        try? modelContext.save()
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        let count = project.observations.count
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            HStack(spacing: 6) {
                Text("\(count) observation\(count == 1 ? "" : "s")")
                if let latest = project.latestObservationDate {
                    Text("·")
                    Text(latest, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager

    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    /// Restores the last viewed project when the app reopens.
    @SceneStorage("selectedProjectID") private var storedSelection = ""
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            ProjectListView(projects: projects, selection: $selection)
        } detail: {
            if let id = selection, let project = projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
                    .id(project.id)
            } else {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Choose a project, or create one to start logging observations.")
                )
            }
        }
        .onAppear {
            // Route SwiftData changes through the window's undo manager so
            // shake-to-undo and ⌘Z work for adds, edits and deletes.
            modelContext.undoManager = undoManager ?? UndoManager()
            if selection == nil, let id = UUID(uuidString: storedSelection) {
                selection = id
            }
        }
        .onChange(of: undoManager) { _, newValue in
            if let newValue { modelContext.undoManager = newValue }
        }
        .onChange(of: selection) { _, newValue in
            storedSelection = newValue?.uuidString ?? ""
        }
    }
}

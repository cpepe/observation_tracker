import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum CSVExportService {
    enum ExportError: LocalizedError {
        case projectMissing
        var errorDescription: String? { "The project could not be found." }
    }

    /// Writes the complete project (every observation and field, ignoring the
    /// chart's range and toggles) to a temporary file and returns its URL.
    /// Reads through a fresh background context so large projects don't block the UI.
    static func writeFile(projectID: PersistentIdentifier, container: ModelContainer) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            guard let project = context.model(for: projectID) as? Project else { throw ExportError.projectMissing }
            let data = CSVWriter.data(fields: project.fields, observations: project.sortedSnapshots())
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(CSVWriter.fileName(projectName: project.name))
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }
}

/// A lazily generated CSV for `ShareLink`: the file is only built when the user shares.
struct ProjectCSVFile: Transferable {
    let projectID: PersistentIdentifier
    let container: ModelContainer
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            SentTransferredFile(try await CSVExportService.writeFile(projectID: file.projectID, container: file.container))
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

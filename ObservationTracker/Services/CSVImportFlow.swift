import SwiftUI
import UniformTypeIdentifiers

struct LoadedCSV: Identifiable {
    let id = UUID()
    let table: CSVTable
    let fileName: String

    var baseName: String { (fileName as NSString).deletingPathExtension }
}

/// Presents the Files picker, parses the chosen CSV on a background task with a
/// cancellable progress overlay, and hands the parsed table to `onLoaded`.
struct CSVImportFlow: ViewModifier {
    @Binding var isPresented: Bool
    let onLoaded: (LoadedCSV) -> Void

    @State private var loadTask: Task<Void, Never>?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
            ) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .overlay {
                if loadTask != nil {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView("Reading file…")
                            Button("Cancel", role: .cancel) { loadTask?.cancel() }
                                .buttonStyle(.bordered)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert(
                "Couldn't Read File",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                actions: { Button("OK") {} },
                message: { Text(errorMessage ?? "") }
            )
    }

    private func load(_ url: URL) {
        let fileName = url.lastPathComponent
        loadTask = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> CSVTable in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try Task.checkCancellation()
                return try CSVParser.parse(data: data)
            }
            do {
                let table = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                loadTask = nil
                onLoaded(LoadedCSV(table: table, fileName: fileName))
            } catch is CancellationError {
                loadTask = nil
            } catch {
                loadTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    func csvImportFlow(isPresented: Binding<Bool>, onLoaded: @escaping (LoadedCSV) -> Void) -> some View {
        modifier(CSVImportFlow(isPresented: isPresented, onLoaded: onLoaded))
    }
}

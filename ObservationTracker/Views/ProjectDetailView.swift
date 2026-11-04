import SwiftData
import SwiftUI

enum DetailSegment: String, CaseIterable, Identifiable {
    case chart, data, overview, stats
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chart: "Chart"
        case .data: "Data"
        case .overview: "Chart & Data"
        case .stats: "Stats"
        }
    }
}

/// What the observation form sheet is opened for.
struct FormRequest: Identifiable {
    enum Kind {
        case new(prefill: [UUID: FieldValue])
        case edit(ObservationRecord)
    }
    let id = UUID()
    let kind: Kind
}

struct BannerState: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct ProjectDetailView: View {
    @Bindable var project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Restores the last viewed segment when the app reopens.
    @SceneStorage("detailSegment") private var segmentRaw = DetailSegment.chart.rawValue

    @State private var analysis: ProjectAnalysis?
    @State private var formRequest: FormRequest?
    @State private var showingTemplateEditor = false
    @State private var showingImporter = false
    @State private var loadedCSV: LoadedCSV?
    @State private var banner: BannerState?

    var body: some View {
        GeometryReader { geo in
            // iPad landscape shows the chart above the table; portrait behaves like iPhone.
            let isWide = horizontalSizeClass == .regular && geo.size.width > geo.size.height
            content(isWide: isWide)
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task(id: analysisKey) { await recompute() }
        .sheet(item: $formRequest) { request in
            ObservationFormView(project: project, request: request) {
                showBanner("Observation deleted")
            }
        }
        .sheet(isPresented: $showingTemplateEditor) {
            ProjectEditorView(mode: .edit(project))
        }
        .csvImportFlow(isPresented: $showingImporter) { loadedCSV = $0 }
        .sheet(item: $loadedCSV) { csv in
            ImportPreviewView(csv: csv, mode: .existing(project)) { _ in
                showBanner("Import complete")
            }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(isWide: Bool) -> some View {
        let segments: [DetailSegment] = isWide ? [.overview, .stats] : [.chart, .data, .stats]
        let current = resolvedSegment(isWide: isWide)

        VStack(spacing: 0) {
            Picker("View", selection: Binding(get: { current }, set: { segmentRaw = $0.rawValue })) {
                ForEach(segments) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let analysis {
                switch current {
                case .chart:
                    chartView(analysis)
                case .data:
                    dataView(analysis)
                case .overview:
                    VStack(spacing: 0) {
                        chartView(analysis)
                            .frame(maxHeight: .infinity)
                        Divider()
                        dataView(analysis)
                            .frame(maxHeight: .infinity)
                    }
                case .stats:
                    StatsView(analysis: analysis, rangeTitle: project.chartSettings.range.title)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func resolvedSegment(isWide: Bool) -> DetailSegment {
        let stored = DetailSegment(rawValue: segmentRaw) ?? .chart
        switch (stored, isWide) {
        case (.chart, true), (.data, true): return .overview
        case (.overview, false): return .chart
        default: return stored
        }
    }

    private func chartView(_ analysis: ProjectAnalysis) -> some View {
        ProjectChartView(
            analysis: analysis,
            settings: project.chartSettings,
            onChangeMode: { mode in updateSettings { $0.mode = mode } },
            onToggleSeries: { id in
                updateSettings {
                    if $0.hiddenSeries.contains(id) { $0.hiddenSeries.remove(id) } else { $0.hiddenSeries.insert(id) }
                }
            },
            onShowAllSeries: { updateSettings { $0.hiddenSeries = [] } },
            onShowAllTime: { updateSettings { $0.range = .all } },
            onAdd: addObservation
        )
    }

    private func dataView(_ analysis: ProjectAnalysis) -> some View {
        DataTableView(
            analysis: analysis,
            fields: project.visibleFields,
            onEdit: { id in
                if let record = record(id) { formRequest = FormRequest(kind: .edit(record)) }
            },
            onDelete: deleteObservation,
            onDuplicate: { id in
                if let record = record(id) { formRequest = FormRequest(kind: .new(prefill: record.values)) }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if horizontalSizeClass == .regular {
                Button(action: addObservation) {
                    Label("Add Observation", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            Menu {
                Picker("Date Range", selection: Binding(
                    get: { project.chartSettings.range },
                    set: { range in updateSettings { $0.range = range } }
                )) {
                    ForEach(DateRangeOption.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(project.chartSettings.range.title, systemImage: "calendar")
            }
            .accessibilityLabel("Date range, \(project.chartSettings.range.title)")

            ShareLink(
                item: ProjectCSVFile(
                    projectID: project.persistentModelID,
                    container: modelContext.container,
                    fileName: CSVWriter.fileName(projectName: project.name)
                ),
                preview: SharePreview(CSVWriter.fileName(projectName: project.name))
            ) {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }

            Menu {
                Button {
                    showingTemplateEditor = true
                } label: {
                    Label("Edit Project & Fields…", systemImage: "list.bullet.rectangle")
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import CSV…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let banner {
                UndoBanner(message: banner.message) {
                    modelContext.undoManager?.undo()
                    try? modelContext.save()
                    self.banner = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(6))
                    if self.banner?.id == banner.id { withAnimation { self.banner = nil } }
                }
            }
            if horizontalSizeClass != .regular {
                Button(action: addObservation) {
                    Label("Add Observation", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.default, value: banner)
    }

    // MARK: Data

    /// Changes whenever any observation, the template or the chart settings change.
    /// Reading these properties here also registers them for observation.
    private var analysisKey: Int {
        var combined = 0
        for record in project.observations {
            var h = Hasher()
            h.combine(record.id)
            h.combine(record.modifiedAt)
            h.combine(record.timestamp)
            h.combine(record.valuesData)
            combined &+= h.finalize()
        }
        var h = Hasher()
        h.combine(combined)
        h.combine(project.observations.count)
        h.combine(project.fieldsData)
        h.combine(project.chartSettingsData)
        h.combine(Calendar.current.startOfDay(for: .now))
        return h.finalize()
    }

    private func recompute() async {
        let snapshots = project.sortedSnapshots()
        let fields = project.fields
        let settings = project.chartSettings
        let result = await Task.detached(priority: .userInitiated) {
            ProjectAnalysis.compute(snapshots: snapshots, fields: fields, settings: settings)
        }.value
        if !Task.isCancelled { analysis = result }
    }

    private func record(_ id: UUID) -> ObservationRecord? {
        project.observations.first { $0.id == id }
    }

    private func addObservation() {
        formRequest = FormRequest(kind: .new(prefill: [:]))
    }

    private func deleteObservation(_ id: UUID) {
        guard let record = record(id) else { return }
        modelContext.delete(record)
        project.updatedAt = .now
        try? modelContext.save()
        showBanner("Observation deleted")
    }

    private func showBanner(_ message: String) {
        withAnimation { banner = BannerState(message: message) }
    }

    /// Chart settings persist per project but stay off the undo stack.
    private func updateSettings(_ change: (inout ChartSettings) -> Void) {
        modelContext.withoutUndo {
            var settings = project.chartSettings
            change(&settings)
            project.chartSettings = settings
        }
        try? modelContext.save()
    }
}

struct UndoBanner: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
        .accessibilityElement(children: .contain)
    }
}

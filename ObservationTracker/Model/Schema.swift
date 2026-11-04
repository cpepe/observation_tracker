import Foundation
import SwiftData

// The observation model is named `ObservationRecord` rather than `Observation`:
// a type called `Observation` shadows Apple's Observation module, which the
// @Model macro expansion refers to by name, and the project would not compile.

enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Project.self, ObservationRecord.self] }

    @Model final class Project {
        @Attribute(.unique) var id: UUID
        var name: String
        var notes: String
        var createdAt: Date
        /// Bumped on every observation or template change; the project list sorts by it.
        var updatedAt: Date
        /// JSON-encoded `[FieldDefinition]`; array order is display order.
        var fieldsData: Data
        /// JSON-encoded `ChartSettings`.
        var chartSettingsData: Data
        @Relationship(deleteRule: .cascade, inverse: \ObservationRecord.project)
        var observations: [ObservationRecord] = []

        init(name: String, notes: String = "", fields: [FieldDefinition]) {
            id = UUID()
            self.name = name
            self.notes = notes
            createdAt = .now
            updatedAt = .now
            fieldsData = (try? JSONEncoder().encode(fields)) ?? Data()
            chartSettingsData = (try? JSONEncoder().encode(ChartSettings())) ?? Data()
        }

        var fields: [FieldDefinition] {
            get { (try? JSONDecoder().decode([FieldDefinition].self, from: fieldsData)) ?? [] }
            set { fieldsData = (try? JSONEncoder().encode(newValue)) ?? fieldsData }
        }

        var chartSettings: ChartSettings {
            get { (try? JSONDecoder().decode(ChartSettings.self, from: chartSettingsData)) ?? ChartSettings() }
            set { chartSettingsData = (try? JSONEncoder().encode(newValue)) ?? chartSettingsData }
        }

        var visibleFields: [FieldDefinition] { fields.filter { !$0.isHidden } }
    }

    @Model final class ObservationRecord {
        @Attribute(.unique) var id: UUID
        /// The sort key everywhere. Stored to whole seconds.
        var timestamp: Date
        /// Binary-encoded `[UUID: FieldValue]` (see `FieldValueCodec`); a missing key is a blank value.
        var valuesData: Data
        var createdAt: Date
        var modifiedAt: Date
        var project: Project?

        init(timestamp: Date, values: [UUID: FieldValue]) {
            id = UUID()
            self.timestamp = timestamp
            valuesData = FieldValueCodec.encode(values)
            createdAt = .now
            modifiedAt = .now
        }

        var values: [UUID: FieldValue] {
            get { FieldValueCodec.decode(valuesData) }
            set { valuesData = FieldValueCodec.encode(newValue) }
        }

        var snapshot: ObservationSnapshot {
            ObservationSnapshot(id: id, timestamp: timestamp, createdAt: createdAt, values: values)
        }
    }
}

enum ObservationTrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias Project = SchemaV1.Project
typealias ObservationRecord = SchemaV1.ObservationRecord

extension Project {
    /// All observations as value snapshots, oldest first.
    func sortedSnapshots() -> [ObservationSnapshot] {
        observations.map(\.snapshot).sorted(by: ObservationSnapshot.ascending)
    }

    var latestObservationDate: Date? {
        observations.lazy.map(\.timestamp).max()
    }
}

extension ModelContext {
    /// Runs changes that should not land on the undo stack (template edits,
    /// chart settings, project create/delete), keeping undo about observations.
    func withoutUndo(_ changes: () -> Void) {
        guard let undoManager else { changes(); return }
        processPendingChanges()
        undoManager.disableUndoRegistration()
        changes()
        processPendingChanges()
        undoManager.enableUndoRegistration()
    }
}

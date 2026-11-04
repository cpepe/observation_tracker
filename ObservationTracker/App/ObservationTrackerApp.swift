import SwiftData
import SwiftUI

@main
struct ObservationTrackerApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: ObservationTrackerMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            fatalError("Could not open the data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

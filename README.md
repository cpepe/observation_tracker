# Observation Tracker

A universal iPhone and iPad app (iOS/iPadOS 17+) that implements `Observation Tracker — iOS App Spec (v1).md`. It is built with SwiftUI, SwiftData and Swift Charts and has no third-party dependencies.

## Build

1. Install Xcode 16 or later. The project uses folder-synchronized groups, so any file you add under `ObservationTracker/` is picked up automatically.
2. Open `ObservationTracker.xcodeproj`.
3. Choose your team under Signing & Capabilities. The bundle ID is the placeholder `com.example.ObservationTracker`.
4. Run on an iPhone or iPad simulator. ⌘U runs the CSV round-trip tests in `ObservationTrackerTests/`.

## Layout

| Folder | Contents |
| --- | --- |
| `Model/` | SwiftData `VersionedSchema` (`Project`, `ObservationRecord`) and the Codable value types |
| `CSV/` | RFC 4180 writer, parser with delimiter detection, and import analysis (type inference, timestamp formats, duplicates, row errors) |
| `Logic/` | Range filtering, day sections, chart series for all three modes, stats, and value formatting and parsing |
| `Services/` | Lazy CSV export (`Transferable` for `ShareLink`) and the background CSV loading flow |
| `Views/` | Project list, project editor, project screen (chart, data, stats), entry form, import preview |

## Where the code differs from the spec

- **The model is named `ObservationRecord`, not `Observation`.** A type named `Observation` hides Apple's Observation module, which the `@Model` macro refers to by name, so the code would not compile.
- **Some values are stored as encoded `Data`.** Observation values are a compact binary blob, and the template and chart settings are JSON. Each model exposes them as the typed properties from the spec (`values`, `fields`, `chartSettings`). On iOS 17, SwiftData is unreliable with enums that have associated values. Binary values also decode quickly enough for 50,000 observations.
- **`Project.updatedAt` was added** so the project list can sort by most recently updated.
- **Timestamps are stored to whole seconds** so they match their CSV form exactly.
- **There is no `timestamp` index.** SwiftData's `#Index` needs iOS 18, and v1 targets iOS 17.
- **Export from the list swipe action and from the delete dialog** uses the system share sheet with a file generated on demand. The project screen's Share button is a `ShareLink`, as the spec describes.
- **On iPad the data view is a custom sortable list** rather than SwiftUI `Table`. On iOS 17.0, `Table` cannot create one column per template field (that needs `TableColumnForEach`, which arrived in 17.4).

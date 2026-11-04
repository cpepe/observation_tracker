# Observation Tracker — iOS App Spec (v1)

Nov 4, 2026 · @Christopher Pepe

## Overview

Observation Tracker is an iPhone and iPad app for logging timestamped measurements against a user-defined template, then plotting, summarizing and exporting them. All data stays on the device.

**Core concepts**

- **Project:** one work stream. It owns a template and all observations recorded against it.
- **Template:** the ordered list of fields every observation in the project carries. Each field has a user-chosen name (e.g. volume1, unique within the project) and a type: integer, decimal or text. The name labels the field on the entry form, table columns, chart legend, stats cards and CSV header.
- **Observation:** one data point. It always has a timestamp, plus a value for each named template field (any value may be blank).

Example: a project with fields `volume1: decimal`, `volume2: decimal`, `note: text` produces observations like `2026-11-04 08:15 · 12.5 · 9.0 · "after refill"`, and plots two lines: volume1 over time and volume2 over time.

**Design principles**

- Fast entry: logging a reading now should take one tap to open the form and one to save.
- The timestamp is the spine: everything (table order, charts, totals) is ordered by observation time, not entry time.
- Never lose data: no destructive template changes, undo on deletes, and lossless CSV round-trips.
- Simple over clever: native iOS components and frameworks, no accounts, no network.

## Platform and technical foundation

The app targets iOS and iPadOS 17.0 and later, built entirely on Apple frameworks with no third-party dependencies.

| Concern | Choice | Notes |
| --- | --- | --- |
| Minimum OS | iOS / iPadOS 17.0 | Unlocks SwiftData plus Swift Charts selection and scrolling. |
| Devices | iPhone and iPad | Universal app; no Mac Catalyst or visionOS target in v1. |
| UI | SwiftUI | `NavigationSplitView` adapts between iPhone and iPad. |
| Persistence | SwiftData | Single local store; no CloudKit container. |
| Charts | Swift Charts | `LineMark`, `BarMark`, `chartXSelection`, `chartScrollableAxes`. |
| CSV | Hand-written RFC 4180 encoder and parser | Small, testable, no dependency. |
| File I/O | `ShareLink` / `fileExporter` for export, `fileImporter` for import | System share sheet and Files picker. |
| Network | None | The app makes no network requests and needs no entitlements for it. |
| Localization | English in v1 | Numbers and dates display with the device locale; CSV always uses `.` decimals and ISO 8601. |

Accessibility is a v1 requirement: Dynamic Type throughout, VoiceOver labels on every control, and Swift Charts' built-in audio graphs and accessibility descriptions for each chart.

## Data model

Two SwiftData models (`Project`, `Observation`) hold everything; the template and chart settings are Codable values stored on the project, and observation values are a dictionary keyed by field ID.

SwiftData cannot create a table per template, so the template is stored as data. Keying values by a stable field ID (not the field name) is what makes renaming a field free.

```swift
@Model final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var fields: [FieldDefinition]          // order = display order
    var chartSettings: ChartSettings
    @Relationship(deleteRule: .cascade, inverse: \Observation.project)
    var observations: [Observation]
}

struct FieldDefinition: Codable, Identifiable, Hashable {
    let id: UUID                           // never changes
    var name: String                       // renamable
    let type: FieldType                    // fixed at creation
    var isHidden: Bool                     // hidden from entry, chart, stats; still exported
}

enum FieldType: String, Codable { case integer, decimal, text }

enum FieldValue: Codable, Hashable {
    case integer(Int)
    case decimal(Double)
    case text(String)
}

@Model final class Observation {
    @Attribute(.unique) var id: UUID
    var timestamp: Date                    // indexed; the sort key everywhere
    var values: [UUID: FieldValue]         // missing key = blank
    var createdAt: Date
    var modifiedAt: Date
    var project: Project?
}

struct ChartSettings: Codable {
    var mode: ChartMode = .raw             // .raw, .runningTotal, .dailyTotals
    var range: DateRangeOption = .all      // .days7, .days30, .days90, .all
    var hiddenSeries: Set<UUID> = []       // legend toggles
}
```

**Invariants**

- A field's `id` and `type` never change after creation. Fields are never deleted, only hidden.
- Field names are unique within a project (case-insensitive, trimmed) and may not be `timestamp`, which is reserved for CSV.
- A blank value is a missing dictionary key, never a zero or an empty string. Text fields store trimmed text; an empty string after trimming is treated as blank.
- A value's case always matches its field's type. Integer fields use 64-bit `Int`; decimal fields use `Double`.
- Every observation belongs to exactly one project; deleting a project deletes its observations.
- The schema is declared with `VersionedSchema` from v1 so future migrations are straightforward.

## Navigation and screens

The app has two levels, a project list and a project screen, built on `NavigationSplitView`; every other screen is a sheet opened from one of them.

&#91;embedded content: screen map · list, project screen with 3 views, 4 sheets\]

- **iPhone (compact width):** the project list pushes to the project screen. A segmented control at the top switches between Chart, Data and Stats; the range menu and Share button sit in the toolbar; a prominent **Add Observation** button is pinned at the bottom.
- **iPad (regular width):** the project list stays in the sidebar. In landscape the project screen shows the chart above the data table at once, with Stats as a third segment; in portrait it behaves like iPhone. **+** sits in the toolbar, and ⌘N adds an observation with a hardware keyboard.
- **Sheets:** the entry form, template editor, import preview and share sheet all open modally and return to the view the user came from.
- **State restoration:** the app reopens on the last viewed project and segment.

## Projects and templates

Users create projects with a template of at least one numeric field; afterwards they can add, rename, reorder and hide fields, but never delete a field or change its type.

**Project list**

- Shows each project's name, observation count and the date of its latest observation, sorted by most recently updated.
- Empty state explains what a project is and offers a single **New Project** button.
- Swipe actions: Export CSV, Delete.

**Creating a project**

1. Enter a name (required, unique among projects) and optional notes.
2. Add fields: name plus type (Integer, Decimal, Text). Fields can be reordered by drag.
3. Save is enabled once the project has a name and at least one integer or decimal field, since a project with nothing to plot has no chart.

The creation sheet also offers **Import from CSV…**, which builds the project from a file (see CSV import).

**Editing a template after creation**

| Action | Allowed | Effect on existing observations |
| --- | --- | --- |
| Add field | Yes | Existing observations show the new field as blank. |
| Rename field | Yes | None; values are keyed by field ID. |
| Reorder fields | Yes | None; affects entry form, table columns, legend and CSV column order. |
| Hide / unhide field | Yes | Hidden fields leave the entry form, chart, stats and table, but keep their data and stay in CSV export. |
| Change field type | No | Type is shown read-only. |
| Delete field | No | Hide it instead. |

At least one numeric field must remain visible; the app blocks hiding the last one.

**Deleting a project**

A confirmation dialog states how many observations will be deleted and offers **Export CSV first** alongside **Delete**. Deletion is permanent; there is no project-level undo.

## Observation entry and editing

The timestamp fills in automatically with the current date and time and stays editable, so a reading taken earlier can be logged now and still land in its correct place.

**Opening the form**

- A **+** button on the project screen (toolbar on iPad, prominent bottom button on iPhone) opens the entry form as a sheet.
- The form lists the timestamp first, then every visible field in template order.
- The first numeric field gets keyboard focus immediately. Numeric fields use the decimal pad (integer fields: number pad); **Next** moves between fields.

**Timestamp behavior**

1. When the form opens, the timestamp is set to now and marked *live*.
2. While live, it refreshes to the actual time at the moment the user taps **Save**, so a form left open for ten minutes doesn't record a stale time.
3. Editing the date or time (compact `DatePicker`: tap the date for a calendar, the time for a wheel) freezes it at the chosen value.
4. Once edited, a **Now** button appears beside it; tapping it returns to live mode.
5. A timestamp in the future is allowed but shows an inline warning ("This time is in the future") so a mistyped date gets noticed.

Timestamps are stored as absolute instants (`Date`) and displayed in the device's current time zone.

**Values**

- Every field is optional. A blank numeric field is stored as missing, never as 0.
- Integer fields reject decimals; decimal fields accept the locale's decimal separator. Invalid input shows an inline error and disables Save.
- Save requires at least one non-blank value, so empty observations can't be created.

**Editing and deleting**

- Tapping a row in the data table opens the same form, pre-filled. Its timestamp starts frozen at the stored value (never live), with the **Now** button available.
- The edit form includes a **Delete Observation** button. Deletes are also available by swipe in the table.
- Every add, edit and delete is undoable (shake to undo on iPhone, ⌘Z with a keyboard on iPad, plus a transient **Undo** banner after deletes).
- Because everything is sorted by timestamp, a backdated or re-timed observation immediately moves to its correct position in the table, charts, running totals and daily bars.

## Data table

The Data view lists every observation newest first, with one column per visible field, and is where observations are edited and deleted.

- **Columns:** timestamp first, then visible fields in template order. Numbers are right-aligned; text truncates to one line.
- **iPad (regular width):** a SwiftUI `Table` with sortable column headers; default sort is timestamp descending.
- **iPhone (compact width):** a `List` where each row shows the timestamp as a heading and the field values as `name: value` pairs beneath it. Sorting stays timestamp-descending.
- **Section headers by day** ("Today", "Yesterday", then dates) so backfilled entries are easy to spot.
- **Blank values** display as an em dash, never as 0.
- **Range filter:** the table respects the same date range selected on the chart (7 / 30 / 90 days / All), with a count shown ("42 of 310 observations").
- **Row actions:** tap to edit, swipe to delete, long-press for Duplicate (copies values with a live timestamp, handy for repeated readings).
- **Performance:** rows load lazily; the table should scroll smoothly at 50,000 observations.

## Charts

Every project plots its visible numeric fields automatically on one shared chart, in one of three modes picked by a segmented control: **Values**, **Running Total** and **Daily Totals**.

**Modes**

| Mode | Mark | Each point or bar is | Blank values |
| --- | --- | --- | --- |
| Values | Line with point markers | The field's value at that observation's timestamp | Skipped; the line connects the neighboring points for that field |
| Running Total | Line | The sum of that field's values from the project's first observation up to and including this one | Contribute nothing; the line stays flat |
| Daily Totals | Grouped bars (one bar per field per day) | The sum of that field's values on that calendar day, in the device's current time zone | Contribute nothing; a day with no values for any visible field has no bars |

Running Total always counts from the project's first observation, even when a shorter date range is shown, so a value on the chart never changes just because the range changed.

**Series and legend**

- Each numeric field is one series with a fixed color from a palette, assigned by template order; colors match across all three modes, the legend and the stats panel.
- Tapping a legend item toggles that series on or off. Toggles persist per project (`ChartSettings.hiddenSeries`).
- Text fields are never plotted. Hidden fields (template setting) never appear in the legend.
- All series share one Y axis, starting at zero for Running Total and Daily Totals, and fitted to the data for Values.

**Date range**

- A range menu offers Last 7 days, Last 30 days, Last 90 days and All; the choice persists per project and also filters the data table and stats.
- Values and Running Total fit the selected range on screen. Daily Totals shows at most 31 days at once and scrolls horizontally (`chartScrollableAxes`) for longer ranges, opening at the most recent day.
- X-axis labels adapt to the span: times within a day, day and month for weeks, month and year beyond that.

**Interaction**

- Touch-and-drag (iPhone) or hover/drag (iPad) uses `chartXSelection` to draw a vertical rule at the nearest observation (or day, in Daily Totals) with a callout listing each visible series' value there.
- Point markers show in Values mode only when 100 or fewer observations are in range, to keep dense charts readable.

**Empty and sparse states**

- No observations: a placeholder with an **Add Observation** button.
- No numeric values in range: "No data in this range" with a button to switch to All.
- A single observation: shown as a lone point (or bar), not an empty chart.
- Every series toggled off: "All series hidden" with a **Show All** button.

## Stats panel

The Stats view shows one card per visible numeric field, computed over the selected date range, using only non-blank values.

| Statistic | Definition |
| --- | --- |
| Count | Number of observations with a value for this field |
| Sum | Total of the values |
| Min / Max | Smallest and largest value, each with its timestamp |
| Mean | Sum ÷ count |
| Daily average | Sum ÷ number of calendar days in the range (from the first observation's day when the range is All) |
| Latest | Most recent value and its timestamp |

- Each card's header uses the field's chart color.
- Integer fields show integer sum, min, max and latest; mean and daily average show up to 2 decimal places.
- A field with no values in range shows "No data" instead of zeros.
- On iPhone the cards stack in a scrolling list; on iPad they flow in a 2–3 column grid.
- Stats are computed in memory on a background task whenever observations or the range change.

## CSV export

Export writes one CSV file per project containing every observation and every field (hidden ones included), and hands it to the system share sheet.

**Flow**

- Triggered from the project screen's Share button or the project list's swipe action.
- Uses `ShareLink` with a `Transferable` CSV document, so the user can save to Files, AirDrop, Mail, Messages, etc. On iPad the sheet appears as a popover automatically.
- Export ignores the chart's date range and series toggles: it is always the complete project, so it doubles as a backup.
- File name: `<project name>_<YYYY-MM-DD>.csv`, with characters invalid in file names replaced by `-`.

**Format**

- RFC 4180: comma-separated, CRLF line endings, UTF-8 with a byte-order mark (so Excel reads non-ASCII text correctly).
- Header row: `timestamp`, then each field's current name in template order.
- One row per observation, oldest first.
- `timestamp`: ISO 8601 with seconds and the UTC offset in effect at that instant in the device's time zone, e.g. `2026-11-04T08:15:00-05:00`.
- Integers as plain digits; decimals with `.` as the separator, no thousands separators, written at full round-trip precision and always with at least one fractional digit (9.0, not 9), so a re-import infers Decimal, not Integer.
- Blank values are empty cells. Text values are quoted when they contain a comma, quote or line break, with embedded quotes doubled.

Example:

```csv
timestamp,volume1,volume2,note
2026-11-03T21:40:00-05:00,12.5,9.0,
2026-11-04T08:15:00-05:00,13.25,,"after refill, cold"
```

## CSV import

Import reads a CSV either into an existing project (matching columns to fields by name) or into a new project (building the template from the header), always through a preview screen before anything is saved.

A file exported by the app must re-import with zero errors and zero data loss, both into its own project and as a new project; this round-trip is a release-blocking test. As a new project, every field keeps its type except a column that is entirely blank, which defaults to Text and can be changed in the preview.

**Into an existing project**

1. From the project screen, choose **Import CSV…** and pick a file via `fileImporter`.
2. The app parses the file and matches header names to field names (case-insensitive, trimmed, hidden fields included).
3. The preview shows matched columns, unmatched columns (each with a toggle: **Ignore** or **Add as new field**, with an inferred type) and fields missing from the file (left blank).
4. It then reports row counts: valid, duplicates to skip, and errors, with each error listed by row number and reason.
5. The user taps **Import N rows** (errors are skipped) or **Cancel**. The whole import is one transaction, and an **Undo Import** banner appears afterwards.

**As a new project**

1. From the New Project sheet, choose **Import from CSV…** and pick a file.
2. The project name defaults to the file name without its extension.
3. Each non-timestamp column becomes a field, with its type inferred from the column's non-empty values: all whole numbers → Integer; all numbers → Decimal; anything else (or no values at all) → Text.
4. The preview lets the user rename fields, change inferred types (only to a type every value fits, or to Text) and exclude columns, then shows the same row counts and errors.
5. Saving creates the project and its observations in one transaction.

**Parsing rules**

- Delimiter is auto-detected from the header row: comma, semicolon or tab. A UTF-8 byte-order mark is ignored.
- The timestamp column is the one named `timestamp`, `datetime`, `date` or `time` (case-insensitive); if none matches, the preview asks the user to pick a column. A file with no usable timestamp column can't be imported.
- Accepted timestamp formats: ISO 8601 with or without an offset (no offset means the device's time zone), `yyyy-MM-dd HH:mm[:ss]`, `yyyy-MM-dd` (midnight), and the device locale's short numeric date with optional time (e.g. `11/4/2026 8:15 AM` in the US).
- Numbers: `.` decimal separator for comma- or tab-delimited files; `,` is also accepted in semicolon-delimited files. Surrounding whitespace is trimmed.
- A row is an error if its timestamp doesn't parse, a numeric cell doesn't parse for its field's type (e.g. `3.5` in an Integer field), or it has more cells than the header.
- An empty cell is a blank value. A row whose cells are all empty is silently skipped.
- A row is a duplicate if an existing or earlier imported observation has the same timestamp (to the second) and the same value for every imported field. Duplicates are skipped, so re-importing a backup doesn't double the data.

## Edge cases and validation

These rules cover the situations most likely to cause wrong numbers or lost data.

| Situation | Behavior |
| --- | --- |
| Device time zone changes (travel, DST) | Timestamps are absolute instants, so nothing is altered. Display, day sections and Daily Totals use the current time zone, so an observation near midnight may appear under a different day after travel. |
| Two observations with the same timestamp | Allowed. Both appear; ties sort by `createdAt`. Values mode draws both points. |
| Very large or small numbers | Integer input beyond 64-bit range is rejected. Decimals are limited to finite `Double` values; `NaN` and infinity are rejected on entry and import. |
| Integer sums overflowing | Running and daily totals of integer fields are computed as `Double` once they exceed 64-bit range, so the chart never crashes. |
| Duplicate or reserved field name | Rejected inline on create and rename: names must be unique per project (case-insensitive) and not `timestamp`. |
| Field name containing commas or quotes | Allowed; CSV export quotes the header cell. |
| Very long text values | Stored in full; truncated to one line in the table, shown in full in the edit form and CSV. |
| Spreadsheet formula injection (text starting with `=`, `+`, `-`, `@`) | Exported as-is to preserve round-trips; documented in the app's export help text. |
| App terminated mid-entry | An unsaved entry form is discarded; saved observations are committed immediately. |
| Import of a huge file | Parsed on a background task with a progress indicator and Cancel; tested at 50,000 rows. |
| Storage full | Saves that fail show an alert and leave the form open so nothing typed is lost. |

## Out of scope for v1

These are deliberately excluded to keep v1 small; the data model leaves room for each.

- **Sync and backup:** iCloud/CloudKit sync, multi-device use, accounts. CSV export is the backup path.
- **Field options:** units, required fields, min/max validation, default values, choice (pick-list) fields, field deletion and type changes.
- **Charts:** per-field or dual Y axes, separate stacked charts, custom date ranges, trend lines, moving averages, charting text fields.
- **Data:** export of all projects in one file, JSON export, photos or attachments on observations, search and filtering by value.
- **Platform:** Mac Catalyst, Apple Watch, widgets, Siri/Shortcuts, Live Activities, reminders to log.
- **Localization** beyond English.

Likely first candidates for v2 are units (shown in axis labels and CSV headers), a home-screen widget for quick entry, and iCloud sync.

import XCTest
@testable import ObservationTracker

/// The CSV round-trip is release-blocking: an exported file must re-import with
/// zero errors and zero data loss, both into its own project and as a new project.
final class CSVRoundTripTests: XCTestCase {
    let eastern = TimeZone(identifier: "America/New_York")!
    let usLocale = Locale(identifier: "en_US")

    let volume1 = FieldDefinition(name: "volume1", type: .decimal)
    let volume2 = FieldDefinition(name: "volume2", type: .decimal)
    let count = FieldDefinition(name: "count", type: .integer)
    let note = FieldDefinition(name: "note, \"quoted\"", type: .text)
    let hidden = FieldDefinition(name: "hidden", type: .integer, isHidden: true)

    var fields: [FieldDefinition] { [volume1, volume2, count, note, hidden] }

    func makeObservations() -> [ObservationSnapshot] {
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        return [
            ObservationSnapshot(id: UUID(), timestamp: base, createdAt: base, values: [
                volume1.id: .decimal(12.5), volume2.id: .decimal(9.0), count.id: .integer(3),
            ]),
            ObservationSnapshot(id: UUID(), timestamp: base.addingTimeInterval(3600), createdAt: base, values: [
                volume1.id: .decimal(13.25), note.id: .text("after refill, cold \"really\"\nsecond line"),
                hidden.id: .integer(-42),
            ]),
            ObservationSnapshot(id: UUID(), timestamp: base.addingTimeInterval(7200), createdAt: base, values: [
                volume1.id: .decimal(0.1 + 0.2), count.id: .integer(Int.max), note.id: .text("=SUM(A1)"),
            ]),
            // Same instant as the first, different values: both must survive.
            ObservationSnapshot(id: UUID(), timestamp: base, createdAt: base.addingTimeInterval(1), values: [
                volume2.id: .decimal(1e-7), count.id: .integer(Int.min),
            ]),
        ]
    }

    func testExportFormat() {
        let csv = CSVWriter.csv(fields: fields, observations: makeObservations(), timeZone: eastern)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}timestamp,volume1,volume2,count,\"note, \"\"quoted\"\"\",hidden\r\n"))
        XCTAssertTrue(csv.contains(",12.5,9.0,3,,\r\n"), "decimals keep a fractional digit; blanks are empty")
        XCTAssertTrue(csv.contains("-05:00,") || csv.contains("-04:00,"), "timestamps carry the UTC offset")
        XCTAssertEqual(CSVWriter.decimalString(9), "9.0")
        XCTAssertEqual(CSVWriter.fileName(projectName: "A/B: test", date: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian)).hasSuffix(".csv"), true)
    }

    func testRoundTripIntoOwnProjectSkipsEverythingAsDuplicates() throws {
        let observations = makeObservations()
        let data = CSVWriter.data(fields: fields, observations: observations, timeZone: eastern)
        let table = try CSVParser.parse(data: data)

        let ts = try XCTUnwrap(CSVImportAnalyzer.timestampColumn(in: table.header))
        let targets = fields.enumerated().map { ImportTarget(column: $0.offset + 1, fieldID: $0.element.id, type: $0.element.type) }
        XCTAssertEqual(table.header.dropFirst().map { $0 }, fields.map(\.name))

        let evaluation = try CSVImportAnalyzer.evaluate(
            table: table, timestampColumn: ts, targets: targets, existing: observations, timeZone: eastern, locale: usLocale
        )
        XCTAssertEqual(evaluation.errors.count, 0, "\(evaluation.errors)")
        XCTAssertEqual(evaluation.rows.count, 0)
        XCTAssertEqual(evaluation.duplicateCount, observations.count)
    }

    func testRoundTripAsNewProjectIsLossless() throws {
        let observations = makeObservations()
        let data = CSVWriter.data(fields: fields, observations: observations, timeZone: eastern)
        let table = try CSVParser.parse(data: data)
        let ts = try XCTUnwrap(CSVImportAnalyzer.timestampColumn(in: table.header))

        // Every field keeps its type (no column here is entirely blank).
        var targets: [ImportTarget] = []
        for (i, field) in fields.enumerated() {
            let info = CSVImportAnalyzer.columnInfo(table: table, column: i + 1)
            XCTAssertEqual(info.inferredType, field.type, "column \(field.name)")
            targets.append(ImportTarget(column: i + 1, fieldID: field.id, type: info.inferredType))
        }

        let evaluation = try CSVImportAnalyzer.evaluate(
            table: table, timestampColumn: ts, targets: targets, existing: [], timeZone: eastern, locale: usLocale
        )
        XCTAssertEqual(evaluation.errors.count, 0, "\(evaluation.errors)")
        XCTAssertEqual(evaluation.duplicateCount, 0)
        XCTAssertEqual(evaluation.rows.count, observations.count)

        let expected = observations.sorted(by: ObservationSnapshot.ascending)
        for (row, original) in zip(evaluation.rows, expected) {
            XCTAssertEqual(row.timestamp, original.timestamp)
            XCTAssertEqual(row.values, original.values)
        }
    }

    func testEntirelyBlankColumnDefaultsToText() throws {
        let table = try CSVParser.parse("timestamp,a,b\r\n2026-11-04T08:15:00-05:00,1,\r\n")
        XCTAssertEqual(CSVImportAnalyzer.columnInfo(table: table, column: 2).inferredType, .text)
        XCTAssertEqual(CSVImportAnalyzer.columnInfo(table: table, column: 2).allowedTypes, [.integer, .decimal, .text])
    }

    func testParserHandlesDelimitersAndErrors() throws {
        let semicolon = try CSVParser.parse("Date;value\n2026-11-04 08:15;3,5\n2026-11-05;x\n;;\n2026-11-06;1;2\n")
        XCTAssertEqual(semicolon.delimiter, ";")
        let id = UUID()
        let evaluation = try CSVImportAnalyzer.evaluate(
            table: semicolon, timestampColumn: 0,
            targets: [ImportTarget(column: 1, fieldID: id, type: .decimal)],
            existing: [], timeZone: eastern, locale: usLocale
        )
        XCTAssertEqual(evaluation.rows.count, 1)
        XCTAssertEqual(evaluation.rows.first?.values[id], .decimal(3.5))
        XCTAssertEqual(evaluation.errors.map(\.row), [3, 5])

        let tab = try CSVParser.parse("time\tn\n11/4/2026 8:15 AM\t2\n")
        XCTAssertEqual(tab.delimiter, "\t")
        let intEval = try CSVImportAnalyzer.evaluate(
            table: tab, timestampColumn: 0,
            targets: [ImportTarget(column: 1, fieldID: id, type: .integer)],
            existing: [], timeZone: eastern, locale: usLocale
        )
        XCTAssertEqual(intEval.errors.count, 0, "\(intEval.errors)")
        XCTAssertEqual(intEval.rows.first?.values[id], .integer(2))
    }

    func testIntegerFieldRejectsDecimal() throws {
        let table = try CSVParser.parse("timestamp,n\n2026-11-04,3.5\n")
        let evaluation = try CSVImportAnalyzer.evaluate(
            table: table, timestampColumn: 0,
            targets: [ImportTarget(column: 1, fieldID: UUID(), type: .integer)],
            existing: [], timeZone: eastern, locale: usLocale
        )
        XCTAssertEqual(evaluation.errors.count, 1)
    }

    func testValueCodecRoundTrip() {
        let values: [UUID: FieldValue] = [
            UUID(): .integer(Int.min), UUID(): .decimal(-0.000123), UUID(): .text("héllo 👋"), UUID(): .text(""),
        ]
        XCTAssertEqual(FieldValueCodec.decode(FieldValueCodec.encode(values)), values)
        XCTAssertEqual(FieldValueCodec.decode(FieldValueCodec.encode([:])), [:])
    }

    func testRunningTotalIgnoresRange() {
        let f = FieldDefinition(name: "v", type: .integer)
        let now = Date()
        let old = ObservationSnapshot(id: UUID(), timestamp: now.addingTimeInterval(-60 * 86_400), createdAt: now, values: [f.id: .integer(10)])
        let recent = ObservationSnapshot(id: UUID(), timestamp: now.addingTimeInterval(-60), createdAt: now, values: [f.id: .integer(5)])
        var settings = ChartSettings()
        settings.mode = .runningTotal
        settings.range = .days7
        let analysis = ProjectAnalysis.compute(snapshots: [old, recent], fields: [f], settings: settings, now: now)
        XCTAssertEqual(analysis.chart.points.map(\.value), [15])
        XCTAssertEqual(analysis.stats.first?.integerSum, 5)
        XCTAssertEqual(analysis.inRange.count, 1)
    }
}

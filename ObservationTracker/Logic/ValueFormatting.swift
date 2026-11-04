import SwiftUI

enum ValueFormatter {
    static let blank = "—"

    /// Locale-aware display of a stored value; blanks show as an em dash, never 0.
    static func display(_ value: FieldValue?) -> String {
        switch value {
        case nil: blank
        case .integer(let i): i.formatted()
        case .decimal(let d): display(decimal: d)
        case .text(let s): s
        }
    }

    static func display(decimal d: Double, maxFraction: Int = 6) -> String {
        d.formatted(.number.precision(.fractionLength(0...maxFraction)))
    }

    static func display(number: Double, type: FieldType) -> String {
        type == .integer ? display(decimal: number, maxFraction: 0) : display(decimal: number)
    }

    /// Text placed in an input field when editing a stored value.
    static func editingText(_ value: FieldValue, locale: Locale = .current) -> String {
        switch value {
        case .integer(let i): return String(i)
        case .decimal(let d):
            let sep = locale.decimalSeparator ?? "."
            return "\(d)".replacingOccurrences(of: ".", with: sep)
        case .text(let s): return s
        }
    }

    enum InputError: Error, Equatable {
        case notWholeNumber, notNumber, outOfRange

        var message: String {
            switch self {
            case .notWholeNumber: "Enter a whole number."
            case .notNumber: "Enter a number."
            case .outOfRange: "This number is too large."
            }
        }
    }

    /// Parses form input. `.success(nil)` means blank.
    static func parseInput(_ text: String, type: FieldType, locale: Locale = .current) -> Result<FieldValue?, InputError> {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .success(nil) }
        switch type {
        case .text:
            return .success(.text(s))
        case .integer:
            if let i = Int(s) { return .success(.integer(i)) }
            if s.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "+" }) { return .failure(.outOfRange) }
            return .failure(.notWholeNumber)
        case .decimal:
            let sep = locale.decimalSeparator ?? "."
            let normalized = sep == "." ? s : s.replacingOccurrences(of: sep, with: ".")
            guard let d = Double(normalized) else { return .failure(.notNumber) }
            guard d.isFinite else { return .failure(.outOfRange) }
            return .success(.decimal(d))
        }
    }
}

enum Palette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .red, .mint, .cyan, .yellow]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

extension Date {
    /// "Today", "Yesterday", or the abbreviated date.
    var daySectionTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        return formatted(date: .abbreviated, time: .omitted)
    }
}

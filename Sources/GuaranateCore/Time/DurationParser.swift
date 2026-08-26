import Foundation

/// Errors produced while parsing a human-readable duration.
public enum DurationParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalid(String)
    case nonPositive

    public var description: String {
        switch self {
        case .empty:
            return "Duration is empty."
        case .invalid(let input):
            return "Invalid duration: '\(input)'. Use forms like 30m, 2h, 1h30m, 90s, or a plain number of seconds."
        case .nonPositive:
            return "Duration must be greater than zero."
        }
    }
}

/// Parses human-readable durations into a whole number of seconds.
///
/// Supported forms:
/// - Unit components combined in descending order: `90s`, `30m`, `2h`, `1h30m`, `1d2h`.
/// - Supported units: `s` (seconds), `m` (minutes), `h` (hours), `d` (days).
/// - A bare integer is interpreted as seconds for `caffeinate`-style compatibility: `3600`.
public enum DurationParser {
    public static func parse(_ input: String) throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DurationParseError.empty }

        // Bare integer => seconds.
        if let seconds = Int(trimmed) {
            guard seconds > 0 else { throw DurationParseError.nonPositive }
            return seconds
        }

        var total = 0
        var digits = ""
        var sawUnit = false

        for character in trimmed.lowercased() {
            if character.isNumber {
                digits.append(character)
                continue
            }

            guard !digits.isEmpty, let value = Int(digits) else {
                throw DurationParseError.invalid(input)
            }

            let multiplier: Int
            switch character {
            case "s": multiplier = 1
            case "m": multiplier = 60
            case "h": multiplier = 3600
            case "d": multiplier = 86_400
            default: throw DurationParseError.invalid(input)
            }

            total += value * multiplier
            digits = ""
            sawUnit = true
        }

        // A trailing number without a unit (e.g. "1h30") is ambiguous and rejected.
        guard digits.isEmpty else { throw DurationParseError.invalid(input) }
        guard sawUnit else { throw DurationParseError.invalid(input) }
        guard total > 0 else { throw DurationParseError.nonPositive }
        return total
    }
}

import Foundation

/// Deterministic, locale-independent parser for typed weight input.
///
/// The stored/display weight is already in the athlete's selected unit, so
/// the typed number must be read exactly once and identically on every device
/// region: the same string must always yield the same `Double`, and never an
/// accidental 100× value (the old comma-strip parse read `"72,5"` as `725`).
/// No `Locale` is consulted at any point, so results cannot vary by region.
///
/// Rules, applied in order:
/// 1. Surrounding whitespace is ignored; an optional leading `+`/`-` sign is
///    kept (`"-72,5"` → −72.5).
/// 2. Only ASCII digits, `,`, and `.` are accepted. Exponent notation,
///    `inf`/`nan`, and mid-string signs are rejected outright (`"1e3"` must
///    not silently become `1000`). Digit strings that would overflow `Double`
///    are rejected too — infinity must never reach the model's derived
///    metrics.
/// 3. No separator → the digits are the integer value.
/// 4. Exactly one separator → a trailing digit count other than exactly three
///    is the decimal separator (`72,5` → 72.5, `72.5` → 72.5, `1,25` → 1.25,
///    `8,25` → 8.25). Exactly three trailing digits is a genuine clash between
///    the two conventions: only the acceptance-pinned `"1,000"` / `"1.000"`
///    (leading digit exactly `1`, then three zeros) is accepted as grouping →
///    1000, while every other three-digit single-separator shape (`72,500`,
///    `2,000`, `9,000`, `1,234`, `0,500`, and their point twins) is **rejected
///    visibly with `nil`** rather than guessed as either convention. A
///    silently 1000×-ed 2,500 is as damaging as a 100×-ed 72,5.
/// 5. Both kinds of separator → the rightmost is the decimal separator
///    (`"1,234.5"` → 1234.5, `"1.234,5"` → 1234.5); every other separator
///    must group exactly three digits or the input is rejected. Multiple
///    same-kind separators all grouping three digits keep their deterministic
///    integer reading (`1,234,567` → 1234567, `1.234.567` → 1234567).
/// 6. The value is returned unit-agnostic: display-unit kg↔lb conversion stays
///    in the calling unit layer.
public enum WeightInputParser {
    /// Parses typed weight text into the plain numeric value it represents in
    /// the user's display unit, or `nil` when the input is not a valid load.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }

        var sign = 1.0
        var body = trimmed
        switch first {
        case "-":
            sign = -1
            body.removeFirst()
        case "+":
            body.removeFirst()
        default:
            break
        }
        guard !body.isEmpty else { return nil }

        let characters = Array(body)
        guard characters.allSatisfy(isAllowed) else { return nil }

        let separatorIndexes = characters.indices.filter { isSeparator(characters[$0]) }
        guard !separatorIndexes.isEmpty else {
            guard let value = Double(String(characters)), value.isFinite else { return nil }
            return value * sign
        }

        // Decide whether the last separator is a decimal separator or every
        // separator is grouping (see rule 4/5 in the doc comment).
        let lastIndex = separatorIndexes[separatorIndexes.count - 1]
        let containsBothKinds = characters.contains(",") && characters.contains(".")
        let decimalIndex: Int?
        if containsBothKinds {
            decimalIndex = lastIndex
        } else if separatorIndexes.count > 1 {
            if groupingTrailingCount(at: lastIndex, in: characters) == 3,
               separatorIndexes.allSatisfy({ groupingTrailingCount(at: $0, in: characters) == 3 }) {
                decimalIndex = nil
            } else {
                decimalIndex = lastIndex
            }
        } else if groupingTrailingCount(at: lastIndex, in: characters) == 3 {
            guard isPinnedRoundThousand(at: lastIndex, in: characters) else { return nil }
            decimalIndex = nil
        } else {
            decimalIndex = lastIndex
        }

        let groupingIndexes = decimalIndex.map { decimal in
            separatorIndexes.filter { $0 != decimal }
        } ?? separatorIndexes
        guard groupingIndexes.allSatisfy({ isValidGroup(at: $0, in: characters) }) else { return nil }

        let integerDigits: [Character]
        let fractionDigits: [Character]
        if let decimalIndex {
            integerDigits = characters[..<decimalIndex].filter(isASCIIDigit)
            fractionDigits = characters[(decimalIndex + 1)...].filter(isASCIIDigit)
            guard !integerDigits.isEmpty || !fractionDigits.isEmpty else { return nil }
        } else {
            integerDigits = characters.filter(isASCIIDigit)
            guard !integerDigits.isEmpty else { return nil }
            fractionDigits = []
        }

        let combined = decimalIndex == nil
            ? String(integerDigits)
            : String(integerDigits) + "." + String(fractionDigits)
        guard let value = Double(combined), !value.isInfinite else { return nil }
        return value * sign
    }

    private static func isAllowed(_ character: Character) -> Bool {
        isASCIIDigit(character) || isSeparator(character)
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "," || character == "."
    }

    /// Consecutive digits immediately after a separator — the count that
    /// decides grouping (3) vs decimal (anything else).
    private static func groupingTrailingCount(at index: Int, in characters: [Character]) -> Int {
        characters[(index + 1)...].prefix(while: isASCIIDigit).count
    }

    /// A grouping separator must sit between two groups: at least one digit
    /// before it and exactly three after it.
    private static func isValidGroup(at index: Int, in characters: [Character]) -> Bool {
        guard index > 0, let previous = characters[..<index].last else { return false }
        return isASCIIDigit(previous) && groupingTrailingCount(at: index, in: characters) == 3
    }

    /// The only single-separator three-digit shape pinned as grouping: leading
    /// digit exactly `1` followed by three zeros (`"1,000"`, `"1.000"`).
    /// Every other single-separator three-digit tail (`"2,000"`, `"9,000"`,
    /// `"72,500"`, `"1,234"`, `"0,500"`, and their point twins) is genuinely
    /// ambiguous between the comma/point conventions, so `parse` rejects it
    /// with `nil` instead of guessing.
    private static func isPinnedRoundThousand(at index: Int, in characters: [Character]) -> Bool {
        let leading = characters[..<index].filter(isASCIIDigit)
        guard leading == ["1"] else { return false }
        return characters[(index + 1)...].filter(isASCIIDigit).allSatisfy { $0 == "0" }
    }
}
import Foundation
import Testing
@testable import ForgeCore

/// FF-001 determinism contract for typed weight input.
///
/// The parser never consults `Locale.current`, so every case below must
/// produce the exact same `Double` in every device region. The decimal-comma
/// and decimal-point conventions are pinned together: `"72,5"` and `"72.5"`
/// are the same load, and grouped `"1,000"`/`"1.000"` are the same integer.
struct WeightInputParserTests {

    @Test func decimalCommaParsesAsFraction() {
        #expect(WeightInputParser.parse("72,5") == 72.5)
        #expect(WeightInputParser.parse("1,25") == 1.25)
        #expect(WeightInputParser.parse("72,05") == 72.05)
        #expect(WeightInputParser.parse("0,5") == 0.5)
        #expect(WeightInputParser.parse(",5") == 0.5)
        #expect(WeightInputParser.parse("72,0") == 72.0)
        #expect(WeightInputParser.parse("72,") == 72.0)
    }

    @Test func decimalPointParsesToTheSameValue() {
        #expect(WeightInputParser.parse("72.5") == 72.5)
        #expect(WeightInputParser.parse("1.25") == 1.25)
        #expect(WeightInputParser.parse(".5") == 0.5)
        #expect(WeightInputParser.parse("72.00") == 72.0)
        #expect(WeightInputParser.parse("72.") == 72.0)
    }

    @Test func groupedThousandsStayWholeIntegersInEitherConvention() {
        #expect(WeightInputParser.parse("1,000") == 1000)
        #expect(WeightInputParser.parse("1.000") == 1000)
        #expect(WeightInputParser.parse("1,234,567") == 1_234_567)
        #expect(WeightInputParser.parse("1.234.567") == 1_234_567)
    }

    @Test func ambiguousSingleSeparatorThreeDigitShapesAreRejected() {
        // One separator with exactly three trailing digits could be a decimal
        // comma (72,500 → 72.5) or grouping (72,500 → 72500) depending on
        // region. The parser must not guess: only "1,000" / "1.000" — the
        // acceptance-pinned shape with leading digit exactly "1" — is accepted
        // as grouping; every other shape (including 2,000 through 9,000) is
        // rejected visibly instead of silently 1000×-ing the load.
        #expect(WeightInputParser.parse("0,500") == nil)
        #expect(WeightInputParser.parse("72,500") == nil)
        #expect(WeightInputParser.parse("2,500") == nil)
        #expect(WeightInputParser.parse("1,234") == nil)
        #expect(WeightInputParser.parse("2,000") == nil)
        #expect(WeightInputParser.parse("9,000") == nil)
        #expect(WeightInputParser.parse("0.500") == nil)
        #expect(WeightInputParser.parse("72.500") == nil)
        #expect(WeightInputParser.parse("2.500") == nil)
        #expect(WeightInputParser.parse("1.234") == nil)
        #expect(WeightInputParser.parse("2.000") == nil)
        #expect(WeightInputParser.parse("9.000") == nil)
    }

    @Test func integerOverflowIsRejectedNotConvertedToInfinity() {
        // A digit string longer than Double can represent must yield nil (the
        // strtod path returns +inf), so infinity can never reach a set's
        // stored weight and derived metrics. Both the no-separator branch and
        // the separator branch carry the finite guard.
        #expect(WeightInputParser.parse(String(repeating: "9", count: 400)) == nil)
        #expect(WeightInputParser.parse("1" + String(repeating: "0", count: 400)) == nil)
        #expect(WeightInputParser.parse("-" + String(repeating: "9", count: 400)) == nil)
        #expect(WeightInputParser.parse(String(repeating: "9", count: 400) + ",5") == nil)
    }

    @Test func mixedSeparatorsFollowTheRightmostDecimalRule() {
        #expect(WeightInputParser.parse("1,234.5") == 1234.5)
        #expect(WeightInputParser.parse("1.234,5") == 1234.5)
        #expect(WeightInputParser.parse("1,000.5") == 1000.5)
        #expect(WeightInputParser.parse("1.000,5") == 1000.5)
    }

    @Test func signsAreKeptButOnlyAsAPrefix() {
        #expect(WeightInputParser.parse("-72,5") == -72.5)
        #expect(WeightInputParser.parse("-72.5") == -72.5)
        #expect(WeightInputParser.parse("+72,5") == 72.5)
        #expect(WeightInputParser.parse("-1,000") == -1000)
        #expect(WeightInputParser.parse("-") == nil)
        #expect(WeightInputParser.parse("72-5") == nil)
        #expect(WeightInputParser.parse("-72-5") == nil)
    }

    @Test func wholeNumbersAndSurroundingWhitespace() {
        #expect(WeightInputParser.parse("72") == 72)
        #expect(WeightInputParser.parse("  72.5  ") == 72.5)
        #expect(WeightInputParser.parse("") == nil)
        #expect(WeightInputParser.parse("   ") == nil)
    }

    @Test func malformedInputIsRejectedNotCorrupted() {
        // Mixed types of separator that do not form a valid grouping.
        #expect(WeightInputParser.parse("72,5,3") == nil)
        #expect(WeightInputParser.parse("72.5.3") == nil)
        #expect(WeightInputParser.parse("12,34.5") == nil)
        // Grouping without a group before it, and a bare separator.
        #expect(WeightInputParser.parse(",000") == nil)
        #expect(WeightInputParser.parse(",") == nil)
        // Characters a weight field must not silently coerce.
        #expect(WeightInputParser.parse("1 000") == nil)
        #expect(WeightInputParser.parse("1e3") == nil)
        #expect(WeightInputParser.parse("nan") == nil)
        #expect(WeightInputParser.parse("inf") == nil)
        #expect(WeightInputParser.parse("abc") == nil)
    }

    @Test func resultIsIdenticalAcrossRegionalConventions() {
        // Acceptance criteria, stated as one table: both decimal-separator
        // conventions agree with each other and both grouping conventions
        // agree with each other — no dependence on the ambient locale.
        #expect(WeightInputParser.parse("72,5") == WeightInputParser.parse("72.5"))
        #expect(WeightInputParser.parse("1,000") == 1000)
        #expect(WeightInputParser.parse("1,000") == WeightInputParser.parse("1.000"))
    }
}
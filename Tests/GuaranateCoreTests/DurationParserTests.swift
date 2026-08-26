import XCTest
@testable import GuaranateCore

final class DurationParserTests: XCTestCase {
    func testUnitForms() throws {
        XCTAssertEqual(try DurationParser.parse("90s"), 90)
        XCTAssertEqual(try DurationParser.parse("30m"), 1800)
        XCTAssertEqual(try DurationParser.parse("2h"), 7200)
        XCTAssertEqual(try DurationParser.parse("1h30m"), 5400)
        XCTAssertEqual(try DurationParser.parse("1d2h"), 93_600)
    }

    func testBareIntegerIsSeconds() throws {
        XCTAssertEqual(try DurationParser.parse("3600"), 3600)
        XCTAssertEqual(try DurationParser.parse("1"), 1)
    }

    func testCaseAndWhitespaceInsensitive() throws {
        XCTAssertEqual(try DurationParser.parse(" 1H30M "), 5400)
    }

    func testEmptyThrows() {
        XCTAssertThrowsError(try DurationParser.parse("   ")) { error in
            XCTAssertEqual(error as? DurationParseError, .empty)
        }
    }

    func testNonPositiveThrows() {
        XCTAssertThrowsError(try DurationParser.parse("0")) { error in
            XCTAssertEqual(error as? DurationParseError, .nonPositive)
        }
    }

    func testInvalidUnitThrows() {
        XCTAssertThrowsError(try DurationParser.parse("10x"))
    }

    func testTrailingNumberWithoutUnitThrows() {
        XCTAssertThrowsError(try DurationParser.parse("1h30"))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try DurationParser.parse("abc"))
    }
}

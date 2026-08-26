import XCTest
@testable import GuaranateCore

final class TimeFormattingTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(TimeFormatting.clock(0), "00:00:00")
        XCTAssertEqual(TimeFormatting.clock(59), "00:00:59")
        XCTAssertEqual(TimeFormatting.clock(600), "00:10:00")
        XCTAssertEqual(TimeFormatting.clock(3723), "01:02:03")
        XCTAssertEqual(TimeFormatting.clock(-5), "00:00:00")
    }

    func testCompact() {
        XCTAssertEqual(TimeFormatting.compact(0), "0s")
        XCTAssertEqual(TimeFormatting.compact(45), "45s")
        XCTAssertEqual(TimeFormatting.compact(2832), "47m 12s")
        XCTAssertEqual(TimeFormatting.compact(3723), "1h 2m 3s")
        XCTAssertEqual(TimeFormatting.compact(3600), "1h")
    }
}

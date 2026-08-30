import XCTest
@testable import GuaranateCore

final class DeadlineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testEnd() {
        let deadline = Deadline(start: start, duration: 600)
        XCTAssertEqual(deadline.end, start.addingTimeInterval(600))
    }

    func testElapsedAndRemaining() {
        let deadline = Deadline(start: start, duration: 600)
        let midpoint = start.addingTimeInterval(150)
        XCTAssertEqual(deadline.elapsed(at: midpoint), 150, accuracy: 0.001)
        XCTAssertEqual(deadline.remaining(at: midpoint), 450, accuracy: 0.001)
    }

    func testClampsBeforeStartAndAfterEnd() {
        let deadline = Deadline(start: start, duration: 600)
        XCTAssertEqual(deadline.elapsed(at: start.addingTimeInterval(-50)), 0)
        XCTAssertEqual(deadline.remaining(at: start.addingTimeInterval(9000)), 0)
    }

    func testIsExpired() {
        let deadline = Deadline(start: start, duration: 600)
        XCTAssertFalse(deadline.isExpired(at: start.addingTimeInterval(599)))
        XCTAssertTrue(deadline.isExpired(at: start.addingTimeInterval(600)))
        XCTAssertTrue(deadline.isExpired(at: start.addingTimeInterval(601)))
    }

    func testExtendMovesEndLater() {
        let deadline = Deadline(start: start, duration: 600)
        let now = start.addingTimeInterval(100)
        let extended = deadline.extended(by: 300, at: now)
        XCTAssertEqual(extended.end, deadline.end.addingTimeInterval(300))
        XCTAssertEqual(extended.remaining(at: now), 800, accuracy: 0.001)
        // Elapsed keeps counting from the original start — no reset.
        XCTAssertEqual(extended.elapsed(at: now), 100, accuracy: 0.001)
    }

    func testShortenMovesEndEarlier() {
        let deadline = Deadline(start: start, duration: 600)
        let now = start.addingTimeInterval(100)
        let shortened = deadline.shortened(by: 300, at: now)
        XCTAssertEqual(shortened.end, deadline.end.addingTimeInterval(-300))
        XCTAssertEqual(shortened.remaining(at: now), 200, accuracy: 0.001)
    }

    func testShortenFloorsAtNowAndExpires() {
        let deadline = Deadline(start: start, duration: 600)
        let now = start.addingTimeInterval(100)
        // Shorten past the remaining 500s: end is floored at `now`, not the past.
        let shortened = deadline.shortened(by: 5000, at: now)
        XCTAssertEqual(shortened.end, now)
        XCTAssertEqual(shortened.remaining(at: now), 0, accuracy: 0.001)
        XCTAssertTrue(shortened.isExpired(at: now))
    }

    func testExtendNeverEndsBeforeNow() {
        // A deadline already in the past, extended by less than its overrun,
        // still floors at `now` so it does not resurrect an expired window.
        let deadline = Deadline(start: start, duration: 600)
        let now = start.addingTimeInterval(1000)   // 400s past end
        let extended = deadline.extended(by: 100, at: now)
        XCTAssertEqual(extended.end, now)
        XCTAssertTrue(extended.isExpired(at: now))
    }

    func testAdjustmentsRoundTrip() {
        let deadline = Deadline(start: start, duration: 600)
        let now = start.addingTimeInterval(100)
        let restored = deadline.extended(by: 300, at: now).shortened(by: 300, at: now)
        XCTAssertEqual(restored, deadline)
    }
}

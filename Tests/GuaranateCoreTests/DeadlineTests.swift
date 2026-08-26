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
}

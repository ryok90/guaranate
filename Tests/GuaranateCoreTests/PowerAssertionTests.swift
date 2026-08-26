import XCTest
@testable import GuaranateCore

final class PowerAssertionTypeTests: XCTestCase {
    func testIOKitNames() {
        XCTAssertEqual(PowerAssertionType.preventUserIdleSystemSleep.ioKitName, "PreventUserIdleSystemSleep")
        XCTAssertEqual(PowerAssertionType.preventUserIdleDisplaySleep.ioKitName, "PreventUserIdleDisplaySleep")
        XCTAssertEqual(PowerAssertionType.preventSystemSleep.ioKitName, "PreventSystemSleep")
    }

    func testDisplaySleepPolicy() {
        XCTAssertTrue(PowerAssertionType.preventUserIdleSystemSleep.allowsDisplaySleep)
        XCTAssertFalse(PowerAssertionType.preventUserIdleDisplaySleep.allowsDisplaySleep)
        XCTAssertTrue(PowerAssertionType.preventSystemSleep.allowsDisplaySleep)
    }
}

final class PowerAssertingTests: XCTestCase {
    func testAcquireTracksLiveToken() throws {
        let power = FakePowerAsserting()
        let token = try power.acquire(.preventUserIdleSystemSleep, reason: "test")
        XCTAssertEqual(power.acquireCount, 1)
        XCTAssertTrue(power.active.contains(token))
        XCTAssertEqual(power.lastType, .preventUserIdleSystemSleep)
        XCTAssertEqual(power.lastReason, "test")
    }

    func testReleaseRemovesToken() throws {
        let power = FakePowerAsserting()
        let token = try power.acquire(.preventSystemSleep, reason: "test")
        power.release(token)
        XCTAssertEqual(power.releaseCount, 1)
        XCTAssertFalse(power.active.contains(token))
        XCTAssertTrue(power.active.isEmpty)
    }

    func testDistinctTokensPerAcquire() throws {
        let power = FakePowerAsserting()
        let a = try power.acquire(.preventUserIdleSystemSleep, reason: "a")
        let b = try power.acquire(.preventUserIdleSystemSleep, reason: "b")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(power.active.count, 2)
    }
}

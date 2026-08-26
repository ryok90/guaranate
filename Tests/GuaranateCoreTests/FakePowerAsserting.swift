import GuaranateCore

/// In-memory `PowerAsserting` for tests. Tracks live tokens and call counts so
/// assertion behavior can be verified without touching the host's sleep state.
final class FakePowerAsserting: PowerAsserting, @unchecked Sendable {
    private(set) var active: Set<PowerAssertionToken> = []
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var lastReason: String?
    private(set) var lastType: PowerAssertionType?
    private var nextRaw: UInt32 = 1

    func acquire(_ type: PowerAssertionType, reason: String) throws -> PowerAssertionToken {
        acquireCount += 1
        lastReason = reason
        lastType = type
        let token = PowerAssertionToken(rawValue: nextRaw)
        nextRaw += 1
        active.insert(token)
        return token
    }

    func release(_ token: PowerAssertionToken) {
        releaseCount += 1
        active.remove(token)
    }
}

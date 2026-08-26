import Foundation
import IOKit.pwr_mgt

/// Concrete `PowerAsserting` backed by the native IOKit `IOPMAssertion*` API.
///
/// This is the only type in `GuaranateCore` that touches IOKit; everything else
/// depends on the `PowerAsserting` protocol.
public final class PowerManager: PowerAsserting, @unchecked Sendable {
    public init() {}

    public func acquire(_ type: PowerAssertionType, reason: String) throws -> PowerAssertionToken {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type.ioKitName as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.creationFailed(code: result)
        }
        return PowerAssertionToken(rawValue: assertionID)
    }

    public func release(_ token: PowerAssertionToken) {
        _ = IOPMAssertionRelease(token.rawValue)
    }
}

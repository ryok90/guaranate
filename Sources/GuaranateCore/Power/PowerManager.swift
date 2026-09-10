import Foundation
import IOKit.pwr_mgt

/// Concrete `PowerAsserting` backed by the native IOKit `IOPMAssertion*` API.
///
/// This is the only type in `GuaranateCore` that touches IOKit; everything else
/// depends on the `PowerAsserting` protocol.
public final class PowerManager: PowerAsserting, @unchecked Sendable {
    public init() {}

    public func acquire(
        _ type: PowerAssertionType,
        reason: String,
        onBehalfOf pid: pid_t?
    ) throws -> PowerAssertionToken {
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

        if let pid {
            var value = pid
            if let number = CFNumberCreate(nil, .sInt32Type, &value) {
                IOPMAssertionSetProperty(assertionID, Self.onBehalfOfPIDKey, number)
            }
        }

        return PowerAssertionToken(rawValue: assertionID)
    }

    public func release(_ token: PowerAssertionToken) {
        _ = IOPMAssertionRelease(token.rawValue)
    }
}

extension PowerManager {
    /// `kIOPMAssertionOnBehalfOfPID`, which powerd documents as
    /// `CFSTR("AssertionOnBehalfOfPID")` in `IOPMLibPrivate.h` but does not ship
    /// in the public SDK. It is accounting metadata only — powerd takes no action
    /// when the named process dies — so an unrecognized key is harmless: the
    /// assertion is created either way and only the `pmset` attribution is lost.
    /// `caffeinate` sets the same property the same way for its `-w` mode.
    /// Computed rather than stored: a stored `CFString` global is not `Sendable`
    /// under Swift 6 strict concurrency.
    static var onBehalfOfPIDKey: CFString { "AssertionOnBehalfOfPID" as CFString }
}

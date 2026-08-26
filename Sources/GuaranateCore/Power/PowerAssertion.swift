import Foundation

/// An opaque handle to a created power assertion.
public struct PowerAssertionToken: Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// Errors surfaced by the power-assertion layer.
public enum PowerAssertionError: Error, Equatable, CustomStringConvertible {
    case creationFailed(code: Int32)

    public var description: String {
        switch self {
        case .creationFailed(let code):
            return "Failed to create power assertion (IOReturn 0x\(String(code, radix: 16)))."
        }
    }
}

/// Abstraction over the native power-assertion API.
///
/// Native IOKit interactions sit behind this protocol so the rest of the code
/// can be exercised in tests without changing the host machine's sleep state.
public protocol PowerAsserting: AnyObject, Sendable {
    /// Acquire an assertion of the given `type`, tagged with a human-readable `reason`.
    func acquire(_ type: PowerAssertionType, reason: String) throws -> PowerAssertionToken
    /// Release a previously-acquired assertion. Idempotent for unknown tokens.
    func release(_ token: PowerAssertionToken)
}

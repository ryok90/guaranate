import Foundation

/// The kinds of macOS power assertions Guaranate can create.
///
/// The raw IOKit type strings are hard-coded rather than referencing the
/// `kIOPMAssertionType*` constants so that `GuaranateCore` stays free of an
/// IOKit dependency and remains unit-testable on its own.
public enum PowerAssertionType: String, Sendable, Equatable, CaseIterable {
    /// Prevent idle system sleep while still allowing the display to sleep. The default mode.
    case preventUserIdleSystemSleep
    /// Prevent the display from sleeping (keeps the whole system awake).
    case preventUserIdleDisplaySleep
    /// Prevent system sleep entirely.
    case preventSystemSleep

    /// The IOKit assertion-type string (matches `kIOPMAssertionType*`).
    public var ioKitName: String {
        switch self {
        case .preventUserIdleSystemSleep: return "PreventUserIdleSystemSleep"
        case .preventUserIdleDisplaySleep: return "PreventUserIdleDisplaySleep"
        case .preventSystemSleep: return "PreventSystemSleep"
        }
    }

    /// Whether the display is permitted to sleep under this assertion.
    public var allowsDisplaySleep: Bool {
        switch self {
        case .preventUserIdleDisplaySleep: return false
        case .preventUserIdleSystemSleep, .preventSystemSleep: return true
        }
    }

    /// Short label for the "Assertion" row in terminal output.
    public var assertionLabel: String {
        switch self {
        case .preventUserIdleSystemSleep: return "System sleep"
        case .preventUserIdleDisplaySleep: return "Display sleep"
        case .preventSystemSleep: return "System sleep (full)"
        }
    }

    /// Short label for the "Display" row in terminal output.
    public var displayLabel: String {
        allowsDisplaySleep ? "May sleep" : "Kept awake"
    }
}

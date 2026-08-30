import Foundation

/// Renders a fixed-width text progress bar.
///
/// Pure and deterministic so the bar math is unit-testable without a terminal.
/// The filled and empty portions are returned separately so a caller can color
/// them independently; concatenated they are always exactly `width` display
/// columns wide.
public struct ProgressBar: Sendable, Equatable {
    /// The glyph set used to draw the bar.
    public enum Style: Sendable, Equatable {
        /// Unicode block elements with eighth-cell partial fills for smoothness.
        case unicode
        /// Plain ASCII (`#` filled, `-` empty) for terminals without Unicode.
        case ascii
    }

    /// Number of display columns the bar occupies.
    public let width: Int
    /// The glyph set used to draw the bar.
    public let style: Style

    public init(width: Int, style: Style = .unicode) {
        self.width = max(0, width)
        self.style = style
    }

    /// The filled and empty segments for `fraction` (clamped to `0...1`).
    ///
    /// `filled + empty` is the complete bar, exactly `width` columns wide.
    public func segments(fraction: Double) -> (filled: String, empty: String) {
        guard width > 0 else { return ("", "") }
        let clamped = min(1, max(0, fraction))

        switch style {
        case .unicode:
            // Work in eighths of a cell so the leading edge renders a partial block.
            let eighths = Int((clamped * Double(width) * 8).rounded())
            let full = min(width, eighths / 8)
            let remainder = eighths % 8

            var filled = String(repeating: "█", count: full)
            var emptyCount = width - full
            if remainder > 0 && full < width {
                filled += Self.partials[remainder]
                emptyCount -= 1
            }
            let empty = String(repeating: "░", count: max(0, emptyCount))
            return (filled, empty)

        case .ascii:
            let full = min(width, Int((clamped * Double(width)).rounded()))
            return (
                String(repeating: "#", count: full),
                String(repeating: "-", count: width - full)
            )
        }
    }

    /// The full plain-text bar for `fraction`, `width` columns wide.
    public func render(fraction: Double) -> String {
        let (filled, empty) = segments(fraction: fraction)
        return filled + empty
    }

    /// Horizontal eighth blocks; index `n` (1...7) is `n/8` of a cell wide.
    private static let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
}

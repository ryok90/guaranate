import Foundation
import GuaranateCore

/// Renders timed-session output to a file handle, adapting to whether the
/// destination is an interactive terminal.
///
/// On a color TTY the live frame is a styled, redrawn-in-place layout: a
/// gradient progress bar sized to the terminal, a dot-leader metrics table, and
/// a completion card. Capabilities degrade independently — `NO_COLOR` or a
/// `dumb` terminal drops ANSI color; a non-UTF-8 locale drops Unicode glyphs for
/// an ASCII bar. When stdout is not a TTY (pipes, files, CI), the renderer emits
/// a single start line and a single completion line with no per-second churn —
/// byte-for-byte identical regardless of color/Unicode capability.
final class TerminalRenderer: @unchecked Sendable {
    private let handle: FileHandle
    private let isInteractive: Bool
    private let colorLevel: ColorLevel
    private let useColor: Bool
    private let useUnicode: Bool
    private var previousLineCount = 0
    private var frame = 0
    private var cursorHidden = false

    private let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(
        handle: FileHandle = .standardOutput,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.handle = handle
        let interactive = isatty(handle.fileDescriptor) == 1
        self.isInteractive = interactive

        let term = environment["TERM"]
        let isDumb = term == nil || term == "dumb"
        // NO_COLOR (https://no-color.org): any value, even empty, disables color.
        if !interactive || isDumb || environment["NO_COLOR"] != nil {
            self.colorLevel = .none
        } else if let colorterm = environment["COLORTERM"], colorterm == "truecolor" || colorterm == "24bit" {
            self.colorLevel = .truecolor
        } else if (term ?? "").contains("256color") {
            self.colorLevel = .ansi256
        } else {
            self.colorLevel = .basic
        }
        self.useColor = self.colorLevel != .none
        self.useUnicode = interactive && !isDumb && Self.localeIsUTF8(environment)
    }

    // MARK: - Timed session

    func renderStart(deadline: Deadline?, type: PowerAssertionType) {
        guard !isInteractive else { return }
        let line: String
        if let deadline {
            line = "🌿 Guaranate — staying awake for \(TimeFormatting.compact(deadline.duration)), ends \(endTimeFormatter.string(from: deadline.end))"
        } else {
            line = "🌿 Guaranate — staying awake until interrupted"
        }
        write(line + "\n")
    }

    func renderFrame(deadline: Deadline?, start: Date, type: PowerAssertionType, now: Date) {
        guard isInteractive else { return }
        hideCursor()
        defer { frame += 1 }

        let layout = Layout(columns: terminalColumns())
        var lines = [header(layout), ""]

        if let deadline {
            let fraction = deadline.duration > 0 ? deadline.elapsed(at: now) / deadline.duration : 1
            lines.append(progressBarLine(fraction: fraction, layout: layout))
        } else {
            lines.append(indent + style(spinnerGlyph, .accent) + " " + style("Awake — until interrupted", .value))
        }
        lines.append("")

        let elapsed = deadline?.elapsed(at: now) ?? max(0, now.timeIntervalSince(start))
        lines.append(row("Elapsed", TimeFormatting.clock(elapsed), .value, layout: layout))
        if let deadline {
            lines.append(row("Remaining", TimeFormatting.clock(deadline.remaining(at: now)), .value, layout: layout))
            lines.append(row("Ends", endTimeFormatter.string(from: deadline.end), .value, layout: layout))
        }
        lines.append(row("Assertion", type.assertionLabel, .accent, layout: layout))
        lines.append(row("Display", type.displayLabel, type.allowsDisplaySleep ? .ok : .warn, layout: layout))
        lines.append("")
        lines.append(footer(hasDeadline: deadline != nil))

        redraw(lines)
    }

    func renderFinished(elapsed: TimeInterval, interrupted: Bool, type: PowerAssertionType) {
        let verb = interrupted ? "Stopped" : "Stayed awake"

        guard isInteractive else {
            write("✓ \(verb) after \(TimeFormatting.compact(elapsed))\n")
            write("✓ Sleep-prevention assertion released\n")
            return
        }

        clearPreviousFrame()
        showCursor()

        let layout = Layout(columns: terminalColumns())
        let bar = ProgressBar(width: layout.barCells, style: useUnicode ? .unicode : .ascii)
        let (leftRail, rightRail) = rails
        let (filled, empty) = bar.segments(fraction: 1)
        let completedBar = indent
            + style(leftRail, .track)
            + gradientFilled(filled, empty: empty, barCells: layout.barCells)
            + style(rightRail, .track)
            + "  " + style(useUnicode ? "✓" : "OK", .ok)

        let lines = [
            header(layout), "",
            completedBar, "",
            row(verb, TimeFormatting.compact(elapsed), .ok, layout: layout),
            row("Assertion", type.assertionLabel, .accent, layout: layout),
            "",
            style("Sleep-prevention assertion released", .label),
        ]
        write(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Frame composition

    private let indent = "  "

    private func header(_ layout: Layout) -> String {
        // Center "🌿 Guaranate" over the full content block (indent + bar edge).
        let name = "Guaranate"
        let visibleWidth = 2 + 1 + name.count      // leaf emoji (2 cols) + space + name
        let total = indent.count + layout.alignWidth
        let pad = max(0, (total - visibleWidth) / 2)
        let (r, g, b) = Self.brandGreen
        // Bold brand green on rich terminals; plain green (no bright bold) on basic.
        let code = colorLevel == .truecolor || colorLevel == .ansi256 ? "1;" + foreground(r: r, g: g, b: b) : "32"
        return String(repeating: " ", count: pad) + "🌿 " + paint(name, code: code)
    }

    /// Live control hints. A timed session can extend/shorten/promote; a
    /// permanent one only quits. Keys mirror `TimedSession`'s handler.
    private func footer(hasDeadline: Bool) -> String {
        let sep = style(useUnicode ? "  ·  " : "  |  ", .track)
        var groups: [String] = []
        if hasDeadline {
            groups.append(style("+", .value) + style("/", .label) + style("-", .value) + style(" 5m", .label))
            groups.append(style("p", .value) + style(" permanent", .label))
        }
        groups.append(style("q", .value) + style("/", .label) + style("Ctrl+C", .value) + style(" quit", .label))
        return indent + groups.joined(separator: sep)
    }

    /// A steady spinner for indefinite sessions; advances once per redraw.
    private var spinnerGlyph: String {
        let frames = useUnicode
            ? ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            : ["|", "/", "-", "\\"]
        return frames[frame % frames.count]
    }

    /// End caps that frame the bar; thin rails on Unicode, brackets on ASCII.
    private var rails: (String, String) {
        useUnicode ? ("▏", "▕") : ("[", "]")
    }

    private func progressBarLine(fraction: Double, layout: Layout) -> String {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        let bar = ProgressBar(width: layout.barCells, style: useUnicode ? .unicode : .ascii)
        let (filled, empty) = bar.segments(fraction: fraction)

        let (leftRail, rightRail) = rails
        return indent
            + style(leftRail, .track)
            + gradientFilled(filled, empty: empty, barCells: layout.barCells)
            + style(empty, .track)
            + style(rightRail, .track)
            + "  " + style(String(format: "%3d%%", percent), .value)
    }

    /// Colors a filled bar segment cell-by-cell along the green → berry-red
    /// gradient; brightens the leading cell into a "thumb" when the bar is not
    /// full. Falls back to solid green on basic / no-color terminals.
    private func gradientFilled(_ filled: String, empty: String, barCells: Int) -> String {
        guard colorLevel == .truecolor || colorLevel == .ansi256 else {
            return style(filled, .accent)
        }
        var acc = ""
        let glyphs = Array(filled)
        for (i, glyph) in glyphs.enumerated() {
            let t = barCells > 1 ? Double(i) / Double(barCells - 1) : 0
            let code = gradientForeground(at: t)
            let isThumb = i == glyphs.count - 1 && !empty.isEmpty
            acc += paint(String(glyph), code: isThumb ? "1;" + code : code)
        }
        return acc
    }

    // MARK: - Rendering primitives

    /// A label/value row aligned to the bar's right edge with dim dot leaders.
    private func row(_ label: String, _ value: String, _ valueRole: Role, layout: Layout) -> String {
        let paddedLabel = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        let leaderWidth = max(1, layout.alignWidth - paddedLabel.count - value.count)
        return indent + style(paddedLabel, .label) + style(dotLeaders(leaderWidth), .track) + style(value, valueRole)
    }

    /// Dot leaders: spaces flanking a dotted run, so the value column reads as a
    /// deliberate table without crowding the label or value.
    private func dotLeaders(_ width: Int) -> String {
        guard width > 0 else { return "" }
        let dot: Character = useUnicode ? "·" : "."
        var chars = [Character](repeating: " ", count: width)
        // Interior dots only; keep the first and last cells as spacing.
        var i = 2
        while i < width - 1 {
            chars[i] = dot
            i += 2
        }
        return String(chars)
    }

    private func redraw(_ lines: [String]) {
        clearPreviousFrame()
        write(lines.joined(separator: "\n") + "\n")
        previousLineCount = lines.count
    }

    private func clearPreviousFrame() {
        guard isInteractive, previousLineCount > 0 else { return }
        // Move cursor up to the first rendered line, then clear to end of screen.
        write("\u{1B}[\(previousLineCount)A\u{1B}[0J")
        previousLineCount = 0
    }

    private func hideCursor() {
        guard isInteractive, !cursorHidden else { return }
        write("\u{1B}[?25l")
        cursorHidden = true
    }

    private func showCursor() {
        guard isInteractive, cursorHidden else { return }
        write("\u{1B}[?25h")
        cursorHidden = false
    }

    private func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        handle.write(data)
    }

    // MARK: - Layout

    /// Per-frame geometry derived from the current terminal width.
    private struct Layout {
        /// Number of filled/empty cells in the progress bar.
        let barCells: Int
        /// Column the metrics values and the percentage align their right edge to.
        let alignWidth: Int

        init(columns: Int) {
            // Overhead on the bar line after the indent: two rails, a two-space
            // gap, and the four-column "100%" field.
            let overhead = 1 + 1 + 2 + 4
            let inner = max(24, min(columns - 2, 48))
            barCells = max(10, min(28, inner - overhead))
            alignWidth = barCells + overhead
        }
    }

    /// Current terminal width, falling back to `COLUMNS` then 80.
    private func terminalColumns() -> Int {
        var ws = winsize()
        if ioctl(handle.fileDescriptor, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(columns), n > 0 {
            return n
        }
        return 80
    }

    // MARK: - Styling

    /// Terminal color depth, used to pick between a per-cell gradient and a
    /// solid accent for the progress bar.
    private enum ColorLevel { case none, basic, ansi256, truecolor }

    /// Semantic roles mapped to ANSI SGR codes; a no-op when color is disabled.
    private enum Role {
        case accent, label, value, track, ok, warn

        var sgr: String {
            switch self {
            case .accent: return "32"       // green
            case .label: return "2"         // dim
            case .value: return ""          // default weight, no SGR
            case .track: return "2"         // dim
            case .ok: return "32"           // green
            case .warn: return "33"         // amber
            }
        }
    }

    private func style(_ text: String, _ role: Role) -> String {
        guard useColor, !text.isEmpty, !role.sgr.isEmpty else { return text }
        return "\u{1B}[\(role.sgr)m\(text)\u{1B}[0m"
    }

    /// Wraps `text` in a raw SGR foreground `code`; a no-op when color is off.
    private func paint(_ text: String, code: String) -> String {
        guard useColor, !text.isEmpty, !code.isEmpty else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// The brand green: the gradient's start and the title color. A touch
    /// deeper than a neon terminal green.
    private static let brandGreen = (r: 54, g: 170, b: 76)

    /// SGR foreground for an RGB triple at the current color level; ANSI green
    /// on basic terminals.
    private func foreground(r: Int, g: Int, b: Int) -> String {
        switch colorLevel {
        case .truecolor: return "38;2;\(r);\(g);\(b)"
        case .ansi256:   return "38;5;\(Self.ansi256Index(r: r, g: g, b: b))"
        default:         return "32"
        }
    }

    /// SGR foreground for gradient position `t` in `0...1`, green → berry red.
    private func gradientForeground(at t: Double) -> String {
        let clamped = min(1, max(0, t))
        // guaraná: vivid green ripening to a deep berry red.
        let start = Self.brandGreen
        let end = (r: 222, g: 45, b: 38)
        let r = Int((Double(start.r) + clamped * Double(end.r - start.r)).rounded())
        let g = Int((Double(start.g) + clamped * Double(end.g - start.g)).rounded())
        let b = Int((Double(start.b) + clamped * Double(end.b - start.b)).rounded())
        return foreground(r: r, g: g, b: b)
    }

    /// Maps an RGB triple to the nearest xterm 256-color cube index (16–231).
    private static func ansi256Index(r: Int, g: Int, b: Int) -> Int {
        func level(_ v: Int) -> Int {
            if v < 48 { return 0 }
            if v < 115 { return 1 }
            return min(5, (v - 35) / 40)
        }
        return 16 + 36 * level(r) + 6 * level(g) + level(b)
    }

    private static func localeIsUTF8(_ environment: [String: String]) -> Bool {
        for key in ["LC_ALL", "LC_CTYPE", "LANG"] {
            if let value = environment[key], !value.isEmpty {
                return value.uppercased().contains("UTF-8") || value.uppercased().contains("UTF8")
            }
        }
        return false
    }
}

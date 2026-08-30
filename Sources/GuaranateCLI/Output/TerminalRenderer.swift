import Foundation
import GuaranateCore

/// Renders timed-session output to a file handle, adapting to whether the
/// destination is an interactive terminal.
///
/// On a color TTY the live frame is a styled, redrawn-in-place layout with a
/// progress bar. Capabilities degrade independently: `NO_COLOR` or a `dumb`
/// terminal drops ANSI color; a non-UTF-8 locale drops Unicode glyphs for an
/// ASCII bar. When stdout is not a TTY (pipes, files, CI), the renderer emits a
/// single start line and a single completion line with no per-second churn —
/// byte-for-byte identical regardless of color/Unicode capability.
final class TerminalRenderer: @unchecked Sendable {
    private let handle: FileHandle
    private let isInteractive: Bool
    private let colorLevel: ColorLevel
    private let useColor: Bool
    private let useUnicode: Bool
    private var previousLineCount = 0
    private var frame = 0

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
        defer { frame += 1 }

        var lines = [header, ""]

        if let deadline {
            lines.append(indent + progressBar(deadline: deadline, now: now))
        } else {
            lines.append(indent + style(spinnerGlyph, .accent) + " " + style("Awake — until interrupted", .value))
        }
        lines.append("")

        lines.append(row("Elapsed", TimeFormatting.clock(deadline?.elapsed(at: now) ?? max(0, now.timeIntervalSince(start)))))
        if let deadline {
            lines.append(row("Remaining", TimeFormatting.clock(deadline.remaining(at: now))))
            lines.append(row("Ends", endTimeFormatter.string(from: deadline.end)))
        }
        lines.append(row("Assertion", type.assertionLabel))
        lines.append(row("Display", type.displayLabel))
        lines.append("")
        lines.append(footer)

        redraw(lines)
    }

    func renderFinished(elapsed: TimeInterval, interrupted: Bool) {
        if isInteractive {
            clearPreviousFrame()
        }
        let verb = interrupted ? "Stopped" : "Stayed awake"
        write("✓ \(verb) after \(TimeFormatting.compact(elapsed))\n")
        write("✓ Sleep-prevention assertion released\n")
    }

    // MARK: - Frame composition

    private let indent = "  "

    private var header: String {
        "🌿 " + style("Guaranate", .accentBold)
    }

    private var footer: String {
        style("Press ", .label) + style("Ctrl+C", .value) + style(" or ", .label)
            + style("q", .value) + style(" to stop", .label)
    }

    /// A steady spinner for indefinite sessions; advances once per redraw.
    private var spinnerGlyph: String {
        let frames = useUnicode
            ? ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            : ["|", "/", "-", "\\"]
        return frames[frame % frames.count]
    }

    private func progressBar(deadline: Deadline, now: Date) -> String {
        let fraction = deadline.duration > 0
            ? deadline.elapsed(at: now) / deadline.duration
            : 1
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())

        let width = 32
        let bar = ProgressBar(width: width, style: useUnicode ? .unicode : .ascii)
        let (filled, empty) = bar.segments(fraction: fraction)

        let coloredFilled: String
        if colorLevel == .truecolor || colorLevel == .ansi256 {
            // Paint each filled cell along a green → guaraná-red gradient by position.
            var acc = ""
            for (i, glyph) in filled.enumerated() {
                let t = width > 1 ? Double(i) / Double(width - 1) : 0
                acc += paint(String(glyph), code: gradientForeground(at: t))
            }
            coloredFilled = acc
        } else {
            coloredFilled = style(filled, .accent)
        }

        let caps = useUnicode ? ("", "") : ("[", "]")
        return style(caps.0, .track) + coloredFilled + style(empty, .track) + style(caps.1, .track)
            + "  " + style(String(format: "%3d%%", percent), .value)
    }

    // MARK: - Rendering primitives

    private func row(_ label: String, _ value: String) -> String {
        let padded = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        return indent + style(padded, .label) + style(value, .value)
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

    private func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        handle.write(data)
    }

    // MARK: - Styling

    /// Semantic roles mapped to ANSI SGR codes; a no-op when color is disabled.
    private enum Role {
        case accent, accentBold, label, value, track

        var sgr: String {
            switch self {
            case .accent: return "32"       // green
            case .accentBold: return "1;32" // bold green
            case .label: return "2"         // dim
            case .value: return ""          // default weight, no SGR
            case .track: return "2"         // dim
            }
        }
    }

    private func style(_ text: String, _ role: Role) -> String {
        guard useColor, !text.isEmpty, !role.sgr.isEmpty else { return text }
        return "\u{1B}[\(role.sgr)m\(text)\u{1B}[0m"
    }

    /// Terminal color depth, used to pick between a per-cell gradient and a
    /// solid accent for the progress bar.
    private enum ColorLevel { case none, basic, ansi256, truecolor }

    /// Wraps `text` in a raw SGR foreground `code`; a no-op when color is off.
    private func paint(_ text: String, code: String) -> String {
        guard useColor, !text.isEmpty, !code.isEmpty else { return text }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// SGR foreground for gradient position `t` in `0...1`, green → berry red.
    private func gradientForeground(at t: Double) -> String {
        let clamped = min(1, max(0, t))
        // guaraná: vivid green ripening to a deep berry red.
        let start = (r: 64, g: 192, b: 87)
        let end = (r: 222, g: 45, b: 38)
        let r = Int((Double(start.r) + clamped * Double(end.r - start.r)).rounded())
        let g = Int((Double(start.g) + clamped * Double(end.g - start.g)).rounded())
        let b = Int((Double(start.b) + clamped * Double(end.b - start.b)).rounded())
        switch colorLevel {
        case .truecolor:
            return "38;2;\(r);\(g);\(b)"
        case .ansi256:
            return "38;5;\(Self.ansi256Index(r: r, g: g, b: b))"
        default:
            return "32"
        }
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

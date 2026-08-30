import Foundation
import GuaranateCore

/// Renders timed-session output to a file handle, adapting to whether the
/// destination is an interactive terminal.
///
/// On a TTY the live frame is redrawn in place using ANSI cursor control.
/// When stdout is not a TTY (pipes, files, CI), the renderer degrades to a
/// single start line and a single completion line with no per-second churn.
final class TerminalRenderer: @unchecked Sendable {
    private let handle: FileHandle
    private let isInteractive: Bool
    private var previousLineCount = 0

    private let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
        self.isInteractive = isatty(handle.fileDescriptor) == 1
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

        var lines = [
            "🌿 Guaranate",
            "",
            row("Elapsed", TimeFormatting.clock(max(0, now.timeIntervalSince(start)))),
        ]
        if let deadline {
            lines.append(row("Remaining", TimeFormatting.clock(deadline.remaining(at: now))))
            lines.append(row("Ends", endTimeFormatter.string(from: deadline.end)))
        } else {
            lines.append(row("Mode", "Indefinite — until interrupted"))
        }
        lines.append(row("Assertion", type.assertionLabel))
        lines.append(row("Display", type.displayLabel))
        lines.append("")
        lines.append("Press Ctrl+C to stop")

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

    // MARK: - Rendering primitives

    private func row(_ label: String, _ value: String) -> String {
        let padded = label.padding(toLength: 12, withPad: " ", startingAt: 0)
        return padded + value
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
}

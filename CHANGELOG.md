# Changelog

All notable changes to Guaranate are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add user-facing entries under `## [Unreleased]` in the appropriate category
(`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`). Do not add
version headings or dates — the release process moves `[Unreleased]` into a
dated, versioned section.

## [Unreleased]

### Added

- Install via Homebrew: `brew tap ryok90/guaranate && brew install guaranate`
  pulls the prebuilt universal binary from the tap.
- Running `guaranate` with no duration now stays awake indefinitely until
  interrupted (Ctrl+C / SIGTERM), like `caffeinate` with no timeout (#8).
- Short aliases for every option: `-d`/`--display`, `-s`/`--system`, and
  `-r`/`--reason` (#7).
- Press `q` (or Ctrl+C) to end a live session from the keyboard (#21).
- The user guide is published at <https://guaranate.dev>.
- `guaranate while <command>` holds the assertion for exactly as long as a
  command runs, then exits with the command's own exit code (`128 + signal` when
  a signal kills it, `127` when it is not found, `126` when it is not
  executable). Ctrl+C, Ctrl+Z, stdin, and pipelines behave as they would without
  Guaranate in front, and stdout carries only the command's own output.
  Guaranate's flags go before the command, separated by an optional `--` (#33).
- `guaranate --watch <pid>` / `-w` holds the assertion until an already-running
  process exits, closing the `caffeinate -w` gap. It only observes — the watched
  process is never started, signaled, or killed, and Ctrl+C detaches and leaves
  it running — works for processes owned by other users, survives pid reuse, and
  names the watched process in `pmset -g assertions`. A pid that is unused or has
  already exited is rejected before anything is acquired (#33).

### Changed

- The live terminal frame is now a deliberate terminal UI: timed sessions show
  a gradient progress bar (green→berry-red), a percentage, and a dot-leader
  metrics table beneath a centered header; indefinite sessions show an animated
  spinner. The bar sizes itself to the terminal width, assertion state is
  color-coded (amber when the display is kept awake), the cursor is hidden while
  the frame is live, and completion shows a summary card. The gradient uses
  truecolor or 256-color when available and degrades to solid green otherwise.
  Honors `NO_COLOR` and falls back to plain ASCII (no color, `[####----]` bar)
  on `dumb` or non-UTF-8 terminals; non-TTY output is unchanged (#21).
- The timed surface now lives in a `run` default subcommand, so subcommand names
  are no longer swallowed by the duration argument. Every existing invocation
  behaves exactly as before, and `guaranate run 10m` is now an equivalent
  explicit spelling; `guaranate --help` lists the subcommands, with the duration
  options under `guaranate run --help` (#33).
- A closed or unread output stream no longer ends a session: status output is
  written best-effort, so a status line nobody reads costs the line and never the
  assertion or the command's exit code (#33).
- `GuaranateCore` API: `PowerAsserting.acquire(_:reason:)` is now
  `acquire(_:reason:onBehalfOf:)`, so watch sessions can attribute the assertion
  to the process being watched. Source-breaking for out-of-tree conformers (#33).

### Fixed

- The mascot artwork in `README.md` and the docs site header no longer shows
  stray red specks outside the berry's outline.
- A timed session started in the background no longer stops itself: it leaves the
  terminal's keyboard to the shell instead of taking it over, so it keeps holding
  the assertion rather than being suspended over a keystroke it should never have
  been reading. Ending one from the keyboard still needs the foreground (`q`), or
  `kill` from anywhere.
- A `while` job resumed with `bg` no longer takes the terminal from the shell:
  ownership is decided again on each resume, so `fg` gives the terminal to the
  command and `bg` leaves your prompt's keyboard alone (#33).
- A signal that arrives while a session is starting up, or while a `while` job is
  paused, is neither dropped nor able to end the session before it begins: it is
  recorded before dispositions change and relayed once the job continues (#33).
- `--watch <pid>` no longer treats a failed process lookup as a finished process:
  only a pid that is genuinely gone ends the session, while an operational failure
  is reported and exits `71` rather than releasing the assertion and exiting `0`
  (#33).
- An unread output stream can no longer stall a session: a status line whose reader
  has stopped reading is dropped rather than waited on, so the command still runs
  and Ctrl+C still works when a log pipe fills up (#33).
- A signal that arrives while a `while` job is paused no longer costs the command
  its terminal: the continue is applied before the signal is relayed, so a command
  that survives the signal comes back able to read stdin instead of stopping again
  (#33).
- `--watch <pid>` reports a pid it cannot inspect as a system error (exit `71`)
  rather than as bad input (exit `64`) (#33).

## [0.1.0] - 2026-08-29

### Added

- Native CLI foundation: `guaranate <duration>` keeps macOS awake for a
  human-readable duration (`30m`, `2h`, `1h30m`, `90s`) or a bare integer number
  of seconds.
- Native IOKit power assertion (`PreventUserIdleSystemSleep` by default) via the
  `IOPMAssertion*` API — Guaranate does not wrap `caffeinate`.
- Assertion-mode flags `--display` (keep the display awake) and `--system`
  (prevent all system sleep), plus `--reason` to label the assertion.
- Version flag: `guaranate -v` / `guaranate --version` prints the version and
  exits (`-v` short alias added; see #1).
- Live terminal frame showing elapsed, remaining, and end time; degrades to a
  single start/finish line when stdout is not a TTY.
- Guaranteed assertion cleanup on normal completion, Ctrl+C (exit code `130`),
  and `SIGTERM` — no stale sleep inhibitor is left behind.
- `GuaranateCore` library exposing the `PowerAsserting` protocol, with unit
  tests covering duration parsing, time math, formatting, and assertion
  behavior.
- Project documentation: `README.md`, roadmap (`PLAN.md`), contributor and
  agent conventions (`AGENTS.md`), and an MIT `LICENSE`.
- Continuous integration: a pull-request workflow that builds (release) and
  runs the test suite on macOS, and a workflow enforcing that pull requests
  update this changelog.

### Changed

- The timed-session `Ends` time now includes seconds (`HH:mm:ss`) in both the
  live frame and the non-TTY start line (#3).

[Unreleased]: https://github.com/ryok90/guaranate/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ryok90/guaranate/releases/tag/v0.1.0

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
- `guaranate while <command>` holds the assertion for exactly the lifetime of
  a command: it launches the command, passes its output straight through, and
  exits with the command's own exit code (`128 + signal` when the command is
  killed by one, `127` when it is not found, `126` when it is not executable).
  Ctrl+C, `SIGTERM`, and `SIGHUP` are forwarded to the command and the
  assertion is released only once it has exited, so the command is never
  orphaned and no stale assertion is left behind. Guaranate's own flags go
  before the command, separated by an optional `--` (#33).
- `guaranate --watch <pid>` / `-w` holds the assertion until an already-running
  process exits, closing the `caffeinate -w` gap. It only observes: the watched
  process is never started, signaled, or killed, and Ctrl+C detaches and leaves
  it running. It works for processes owned by other users, is bound to the
  process's (pid, start time) pair so a recycled pid cannot inherit the
  assertion, attributes the assertion to the watched process (so
  `pmset -g assertions` reports `Created for PID: <pid>`), and rejects an
  unused pid before acquiring anything (#33).

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
  are no longer swallowed by the duration argument. Every existing invocation is
  unchanged — `guaranate 10m`, bare `guaranate`, `guaranate -d -r "text" 2h`,
  `guaranate -v`, and `guaranate --version` all behave exactly as before — and
  `guaranate run 10m` is now an equivalent explicit spelling. Root
  `guaranate --help` lists the subcommands (`run (default)` and `while`), with
  the duration argument and `-d`/`-s`/`-r`/`-v` documented under
  `guaranate run --help`; when a subcommand is used, Guaranate's flags follow
  the subcommand name (#33).

### Fixed

- The mascot artwork in `README.md` and the docs site header no longer shows
  stray red specks outside the berry's outline.

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

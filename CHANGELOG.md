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

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

[Unreleased]: https://github.com/ryok90/guaranate/commits/main

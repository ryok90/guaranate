# Contributing to Guaranate

Thanks for your interest in improving Guaranate — a native macOS keep-awake CLI.

This file is the short version for contributors. The authoritative repository
conventions live in [`AGENTS.md`](../AGENTS.md); the product intent lives in
[`GUARANATE.md`](../GUARANATE.md); sequencing and task status live in
[`PLAN.md`](../PLAN.md). Please skim those before a non-trivial change.

## Prerequisites

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+)

## Development

```bash
swift build                 # debug build
swift build -c release      # release build
swift test                  # unit tests (XCTest)
swift run guaranate 10m     # run the CLI
./scripts/smoke.sh          # real IOKit assertion-lifecycle smoke test
```

There is **no** configured linter or formatter — match the style of the
surrounding code. Do not add a formatter config without being asked.

## Architecture boundary (please respect)

```
GuaranateCLI  →  GuaranateCore  →  macOS power APIs (IOKit)
```

- `Sources/GuaranateCore/` is pure, testable logic and **must not import
  IOKit** except inside `Power/PowerManager.swift`. Everything else depends on
  the `PowerAsserting` protocol.
- `Sources/GuaranateCLI/` owns commands, terminal rendering, and process/runtime
  wiring.

New system-API calls belong behind a Core protocol so the rest of the code
stays unit-testable without mutating the host machine's sleep state.

## Pull requests

1. Keep the change as small as the task allows.
2. `swift test` must pass and `swift build -c release` must succeed.
3. For anything that acquires an assertion, smoke-test the real lifecycle with
   `./scripts/smoke.sh` (or the manual steps in `AGENTS.md`).
4. Add a [`CHANGELOG.md`](../CHANGELOG.md) entry under `## [Unreleased]` in the
   correct category (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
   `Security`). CI enforces this. Changes with genuinely no user-facing impact
   (CI tweaks, internal refactors, test-only changes) may skip the entry by
   applying the `skip-changelog` label.
5. Update `README.md` and `PLAN.md` status in the **same** PR that ships a
   feature — code and docs stay in lockstep.

## Non-negotiables

- **Native first.** Use macOS power APIs directly; never shell out to
  `caffeinate`/`pmset` for the implementation.
- **Safe cleanup.** No exit path may leave a stale assertion behind.
- **Stable machine output.** `--json` shape is a contract.
- **Minimal dependencies.** Keep the binary small and native.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](../LICENSE).

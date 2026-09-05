# AGENTS.md

Guidance for AI coding agents working in the Guaranate repository. Humans should
read this too. If anything here conflicts with the product spec, the spec wins —
raise the conflict rather than silently diverging.

## What this project is

Guaranate is a native macOS keep-awake CLI. It manages sleep-prevention sessions
by talking to the IOKit `IOPMAssertion*` API directly. It is **not** a wrapper
around `/usr/bin/caffeinate`.

## Sources of truth

- [`GUARANATE.md`](GUARANATE.md) — product **intent**. Do not edit to record
  progress; it describes what Guaranate should be.
- [`PLAN.md`](PLAN.md) — **sequencing and status**. Update task status here as
  work lands. Task IDs (e.g. `M2-T3`) are stable — append, never renumber.
- [`README.md`](README.md) — user-facing docs. Keep the feature table honest:
  never advertise a command that isn't shipped.
- [`docs/`](docs/) — contributor- and agent-facing documentation: `docs/agents/`
  (agent-skill configuration, see below) and `docs/adr/` (architecture decision
  records). Not published anywhere.
- [`docs-website/`](docs-website/) — the **published** user guide: a
  self-contained Astro Starlight package. User-facing guide content goes here;
  agent and domain docs never do.

Before starting work, read the relevant `PLAN.md` milestone and the spec
sections it references (`Refs:` lines). Verify a task's `Acceptance` criteria —
do not assume them.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `ryok90/guaranate`, driven with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label named after its role: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and one `docs/adr/` at the repository root. See `docs/agents/domain.md`.

## Commands

```bash
swift build                 # debug build
swift build -c release      # release build
swift test                  # run the unit test suite (XCTest)
swift run guaranate 10m     # run the CLI
```

The documentation site is a separate Node package:

```bash
cd docs-website
npm install                 # once
npm run dev                 # local dev server
npm run build               # static build (deploys through Zephyr with a token)
npm run gen:cli             # regenerate the CLI reference from the binary
```

There is **no** configured linter or formatter. Match the style of the
surrounding code; do not introduce a formatter config without being asked.

## Architecture — respect the boundary

```
GuaranateCLI  →  GuaranateCore  →  macOS power APIs (IOKit)
```

- `Sources/GuaranateCore/` — pure, testable logic. **Must not import IOKit**
  except inside `Power/PowerManager.swift`, which is the single IOKit-touching
  type. Everything else depends on the `PowerAsserting` protocol.
- `Sources/GuaranateCLI/` — commands (Swift Argument Parser), terminal
  rendering, and process/runtime wiring. May use Dispatch, signals, `exit()`.
- A future menu-bar app will depend on `GuaranateCore`, not the CLI executable.
  Keep reusable logic in Core; keep terminal/process concerns in the CLI.

New IOKit or system-API calls belong behind a Core protocol so the rest of the
code stays unit-testable without mutating the host machine.

## Code conventions (as established in the codebase)

- Swift 6, `macOS 14+` deployment target.
- Public Core types carry a short doc comment explaining intent and invariants.
- Time math is a **pure function of an injected `now: Date`** (see `Deadline`).
  Do not read the wall clock deep inside logic — inject it so tests are
  deterministic.
- Cross-thread types are explicitly `Sendable`; runtime classes whose state is
  serialized on the main dispatch queue are `final ... : @unchecked Sendable`
  (see `TimedSession`, `TerminalRenderer`). Justify any new `@unchecked`.
- Errors are typed enums conforming to `CustomStringConvertible` with
  user-readable messages (see `DurationParseError`, `PowerAssertionError`).
- CLI parsing/validation lives in `ParsableCommand.validate()`; surface bad
  input as `ValidationError`, not a crash.
- **Every parameter has a short alias.** When adding any flag or option, give it
  a single-character short alias alongside the long form (as `--help`/`-h` and
  `--version`/`-v` do). Choose a mnemonic short, avoid collisions, and treat the
  short name as a stable contract once shipped. Current shorts: `-d`/`--display`,
  `-s`/`--system`, `-r`/`--reason`.

## Testing conventions

- Tests live in `Tests/GuaranateCoreTests/` and use **XCTest**.
- Never touch the host's real sleep state in tests. Use `FakePowerAsserting`
  (the in-memory `PowerAsserting`) to assert acquire/release behavior.
- Prioritize tests for: duration parsing, time calculations, lifecycle state,
  lease expiration, child-process monitoring, signal forwarding, exit-code
  propagation, and JSON output.
- Each test must defend an observable contract, not restate the implementation.

## Changelog workflow

Guaranate is open source and keeps a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
file at [`CHANGELOG.md`](CHANGELOG.md). A PR-time CI check (`.github/workflows/changelog.yml`)
enforces it.

- Every PR with user-facing impact **must** add an entry under the
  `## [Unreleased]` heading, in the correct category: `Added`, `Changed`,
  `Deprecated`, `Removed`, `Fixed`, or `Security`.
- Write entries for users, not implementers: name the command/flag/behavior
  that changed, in the present tense, concisely. Do not paste commit messages.
- **Do not** add version headings or dates, and do not edit already-released
  sections — the release process moves `[Unreleased]` into a dated, versioned
  section.
- Ship the changelog entry in the **same PR** as the change, alongside any
  `PLAN.md` status and `README.md` updates.
- Changes with genuinely no user-facing impact (CI tweaks, internal refactors,
  test-only changes) may skip the entry by applying the `skip-changelog` label
  to the PR. When in doubt, add an entry.

## Verification (do this before claiming done)

1. `swift test` is green.
2. `swift build -c release` succeeds.
3. For anything that acquires an assertion, smoke-test the real lifecycle:
   ```bash
   ./.build/debug/guaranate 4 --reason "verify-XYZ" &
   sleep 1.5; pmset -g assertions | grep verify-XYZ   # assertion is live
   wait $!; echo $?                                    # expected exit code
   pmset -g assertions | grep verify-XYZ || echo released   # nothing left behind
   ```
4. Confirm the interrupt path: `SIGINT` releases the assertion and exits `130`.

## Non-negotiables

- **Native first.** Use macOS power APIs directly. Never shell out to
  `caffeinate`, `pmset` (except as a manual verification aid), or similar for
  the implementation.
- **Safe cleanup is mandatory.** No exit path — normal completion, expiry,
  Ctrl+C, SIGTERM, child crash, expired lease — may leave a stale assertion.
  Privileged sleep-policy changes (future `--clamshell`) must be restored to
  their prior value on every normal exit.
- **Friendly over compatible.** Prefer `guaranate 2h` over `-t 7200`.
- **Machine output is stable.** `--json` output is a contract; don't break its
  shape casually.
- **Minimal dependencies.** Keep the binary small and native. No Node.js in the
  core. Add a dependency only when it clearly improves maintainability.
- **Separation of concerns.** Callers decide *when* to inhibit sleep; Guaranate
  owns *how* the assertion is created, tracked, explained, renewed, released.

## Out of scope (do not build without explicit direction)

Amphetamine-style GUI breadth or a trigger engine; per-harness
(Claude/Codex/OpenCode/Gemini) behavior; AI-activity detection; cross-platform
support; wrapping `/usr/bin/caffeinate`. See `GUARANATE.md` "Non-goals".

## Working agreement

- Make the smallest change that satisfies the task and its acceptance criteria.
- Add a `CHANGELOG.md` entry (see "Changelog workflow") and update `PLAN.md`
  status and `README.md` in the same change that ships a feature — keep code
  and docs in lockstep.
- Do not commit build output; `.build/` and `.serena/` are gitignored.
- Prefer editing existing files over adding new ones; follow the layout in
  `GUARANATE.md` "Suggested project structure".

# Guaranate — Build Plan

Machine-readable breakdown of [`GUARANATE.md`](GUARANATE.md) (the product
spec). `GUARANATE.md` is the source of truth for *intent*; this file is the
source of truth for *sequencing and status*.

## How to read this file

- Milestones are ordered and gated: `MX` should be complete before `M(X+1)`.
- Every task has a stable ID (`M1-T3`). Do not renumber; append instead.
- Status values: `done` · `in-progress` · `todo` · `blocked` · `deferred`.
- `Acceptance` lines are the definition of done — verify them, don't assume.
- `Refs` point at spec sections or source files that anchor the task.

## Status legend

| Mark | Meaning |
| --- | --- |
| `[x]` | done |
| `[~]` | in-progress |
| `[ ]` | todo |
| `[!]` | blocked |
| `[-]` | deferred / out of current scope |

## Milestone index

| ID | Milestone | Status | Depends on |
| --- | --- | --- | --- |
| M1 | v0.1 — Native CLI foundation | done | — |
| M2 | v0.2 — Process lifecycle (`while`, `until`) | todo | M1 |
| M3 | v0.3 — Observability & machine output | todo | M2 |
| M4 | v0.4 — External leases | todo | M3 |
| M5 | v0.5 — Power modes, closed-lid, deeper observability | todo | M4 |
| M6 | Later — Menu-bar companion | deferred | M4 |
| DIST | Distribution (Homebrew, GitHub Releases, npm) | todo | M1 |

---

## M1 — v0.1 Native CLI foundation · `done`

Goal: `guaranate <duration>` is robust before any surface expansion.
Refs: spec "Bootstrap target", "v0.1", "Recommended stack".

- [x] `M1-T1` SwiftPM project along `CLI → Core → power APIs` boundary.
  - Acceptance: `swift build` succeeds; `guaranate` exe + `GuaranateCore` lib targets exist.
  - Refs: `Package.swift`, spec "Suggested project structure".
- [x] `M1-T2` Human-readable duration parsing.
  - Acceptance: `30m`,`2h`,`1h30m`,`90s` parse; bare int = seconds; invalid/zero rejected.
  - Refs: `Sources/GuaranateCore/Time/DurationParser.swift`.
- [x] `M1-T3` Deterministic time math (elapsed/remaining/end/expiry).
  - Acceptance: pure functions of injected `now`; unit-tested.
  - Refs: `Sources/GuaranateCore/Time/Deadline.swift`.
- [x] `M1-T4` Power-assertion abstraction behind a protocol.
  - Acceptance: `PowerAsserting` protocol; IOKit `PowerManager` is the only IOKit-touching type; fake used in tests.
  - Refs: `Sources/GuaranateCore/Power/*`.
- [x] `M1-T5` Native `PreventUserIdleSystemSleep` assertion (default mode).
  - Acceptance: assertion visible in `pmset -g assertions` under the `guaranate` pid; display allowed to sleep.
- [x] `M1-T6` Live terminal frame (elapsed, remaining, ends, assertion, display).
  - Acceptance: matches spec layout on a TTY; single start/finish line off-TTY.
  - Refs: `Sources/GuaranateCLI/Output/TerminalRenderer.swift`.
- [x] `M1-T7` Guaranteed cleanup on expiry, Ctrl+C, and SIGTERM.
  - Acceptance: auto-release after duration (exit 0); SIGINT releases + exits 130; no stale assertion in `pmset`.
  - Refs: `Sources/GuaranateCLI/TimedSession.swift`.
- [x] `M1-T8` Assertion-mode flags `--display` / `--system`; `--reason`.
  - Acceptance: flags map to correct `PowerAssertionType`; mutually-exclusive flags rejected.
  - Refs: `Sources/GuaranateCLI/Guaranate.swift`.
- [x] `M1-T9` Core unit tests.
  - Acceptance: `swift test` green for duration parsing, time math, formatting, assertion abstraction.
  - Refs: `Tests/GuaranateCoreTests/*`.

- [x] `M1-T10` E2E smoke test for the assertion lifecycle in CI.
  - Acceptance: `scripts/smoke.sh` drives the real binary and fails on any
    lifecycle violation (assertion missing while held, stale assertion after
    exit, wrong exit code); covers timed expiry (exit 0) and SIGINT (exit 130);
    runs in CI on `macos-15` after the release build. Not an XCTest — it mutates
    the host's real sleep state, which `swift test` must never do.
  - Refs: `scripts/smoke.sh`, `.github/workflows/ci.yml`.

- [x] `M1-T11` Polished live TTY frame: gradient progress bar, color, clearer
  hierarchy, and a `q` quit key.
  - Acceptance: color TTY shows a width-responsive progress bar with a
    green→berry-red gradient (truecolor/256-color, solid-green fallback), a
    dot-leader metrics table under a centered header, a spinner for the
    indefinite frame, a hidden cursor while live, and a completion summary card;
    `NO_COLOR` / `dumb` / non-UTF-8 fall back to plain ASCII with no stray
    escapes; off-TTY output byte-for-byte unchanged; pressing `q` or Ctrl+C
    releases the assertion and exits 130 with the terminal restored; no redraw
    or cleanup regression.
  - Refs: `Sources/GuaranateCLI/Output/TerminalRenderer.swift`,
    `Sources/GuaranateCLI/TimedSession.swift`,
    `Sources/GuaranateCore/Terminal/ProgressBar.swift`, #21.

---

## M2 — v0.2 Process lifecycle · `todo`

Goal: make `guaranate while -- <cmd>` a signature, polished workflow; add `until` and `watch <pid>`.
Refs: spec "Flagship workflow", "v0.2", "Process model" (in-process case).

- [ ] `M2-T1` `ChildProcess` abstraction in `GuaranateCore`.
  - Acceptance: launch a command with argv; observe exit; testable without a real long-running process.
  - Refs: spec `Sources/.../Process/ChildProcess.swift`.
- [ ] `M2-T2` `while` command: acquire → launch child → hold for child lifetime → release on exit.
  - Acceptance: `guaranate while -- sleep 30` holds the assertion for exactly the child's lifetime.
- [ ] `M2-T3` Signal forwarding to the child (SIGINT/SIGTERM/SIGHUP).
  - Acceptance: Ctrl+C reaches the child; child is not orphaned; parent waits for child teardown.
- [ ] `M2-T4` Child exit-code propagation.
  - Acceptance: `guaranate while -- sh -c 'exit 7'` exits 7; signal-terminated child maps to 128+signal.
- [ ] `M2-T5` Guaranteed assertion release on every `while` exit path.
  - Acceptance: normal exit, child crash, and Ctrl+C all leave no stale assertion.
- [ ] `M2-T6` `while` live frame (Command, Elapsed, Remaining = "process lifetime", Assertion, Display) + completion summary.
  - Acceptance: matches spec examples; degrades off-TTY.
- [ ] `M2-T7` `--reason` on `while`.
  - Acceptance: reason recorded on the assertion.
- [ ] `M2-T8` `until <HH:MM>` command.
  - Acceptance: computes duration to next occurrence of local time; passed-time behavior documented AND tested.
  - Refs: spec "Run until a clock time".
- [ ] `M2-T9` Tests: child monitoring, signal forwarding, exit-code propagation, `until` calculation.
- [ ] `M2-T10` `watch <pid>` command — hold the assertion until an already-running process exits.
  - Acceptance: `guaranate watch <pid>` acquires on start and releases exactly when the PID exits (kqueue `NOTE_EXIT`, not polling); unknown/already-dead PID exits cleanly without acquiring; Ctrl+C releases and detaches without killing the watched process; no stale assertion on any exit path. Reuses the M2-T5 release machinery; accepts `--reason`. Covers the caffeinate `-w <pid>` gap (guaranate otherwise only guards processes it launches).

Design note: the bare-duration root command and subcommands must coexist —
resolve the argument-parser routing so `guaranate 10m` and `guaranate while …`
both work.

---

## M3 — v0.3 Observability & machine output · `todo`

Goal: users answer "what/why is my Mac awake?"; scripts get stable output.
Refs: spec "Observability", "Machine-readable output", "v0.3".

- [ ] `M3-T1` In-process session registry model (id, reason, kind, started-at).
  - Acceptance: session id generation (e.g. `7AE42C`); elapsed derived from start.
  - Refs: spec `Sources/.../Sessions/*`.
- [ ] `M3-T2` `status` — human table of Guaranate-managed sessions + sleep summary.
  - Acceptance: matches spec table; shows display-sleep / idle-system-sleep state.
- [ ] `M3-T3` `status --json` — stable schema.
  - Acceptance: emits `sleepPrevented`, `displaySleepPrevented`, `sessions[]{id,reason,kind,elapsedSeconds}`.
- [ ] `M3-T4` `why` — plain-language explanation (reason, started, display policy).
  - Acceptance: matches spec example.
- [ ] `M3-T5` Global `--json` / `--quiet` conventions across commands.
  - Acceptance: decorated output is never required for automation.
- [ ] `M3-T6` Stable exit codes for scripting, documented.
- [ ] `M3-T7` Tests: JSON schema stability, status/why rendering.

Dependency note: cross-invocation `status`/`why` may require the M4 session
manager. Until then, scope M3 to sessions the current process can observe and
document the limitation.

---

## M4 — v0.4 External leases · `todo`

Goal: stable integration surface for external tools / AI harnesses.
Refs: spec "External tool API", "Lease design", "Process model" (daemon case).

- [ ] `M4-T1` Lease model with TTL + reason (`Lease`, `SessionID`, `SessionManager`).
  - Acceptance: lease has `expiresAt`; TTL expiry releases the assertion.
- [ ] `M4-T2` Minimal background session manager + IPC surviving CLI invocation.
  - Acceptance: independent `acquire`/`renew`/`release` invocations share state reliably; IPC mechanism chosen (UDS/XPC/daemon) and documented.
- [ ] `M4-T3` `acquire --reason --ttl [--json]`.
  - Acceptance: prints lease id (plain) or JSON `{id,expiresAt,type,reason}`; caller need not identify as an AI tool.
- [ ] `M4-T4` `renew <id> --ttl`.
  - Acceptance: extends the lease deadline.
- [ ] `M4-T5` `release <id>` (idempotent).
  - Acceptance: releases; releasing unknown/expired id is a no-op success.
- [ ] `M4-T6` TTL crash-safety.
  - Acceptance: if the caller stops renewing, the assertion is released at TTL — never held indefinitely.
- [ ] `M4-T7` `status`/`why` include lease-backed sessions.
- [ ] `M4-T8` Tests: lease expiration, renew, idempotent release, manager persistence.

---

## M5 — v0.5 Power modes, closed-lid, deeper observability · `todo`

Refs: spec "v0.5", "Assertion modes", "Design principles / Safe cleanup".

- [ ] `M5-T1` Broader assertion-type options with understandable naming, including a disk-idle mode.
  - Acceptance: expose the IOKit `PreventDiskIdleSleep` assertion behind an understandable flag (e.g. `--disk`), mappable alone or alongside existing modes; covers the caffeinate `-m` gap. Document that `--system` (`PreventSystemSleep`) is honored only on AC power, mirroring caffeinate `-s`.
- [ ] `M5-T2` Better inspection of active assertions; clearer `status` / `why`.
- [ ] `M5-T3` `why --all` — explain relevant system-wide assertions where macOS exposes reliable data.
- [ ] `M5-T4` Structured machine-readable status refinements.
- [ ] `M5-T5` Shell completions (Swift Argument Parser).
- [ ] `M5-T6` Prototype privileged `--clamshell` closed-lid support (`guaranate 2h --clamshell`, `while --clamshell`).
  - Acceptance (all required before "stable"): minimal privilege surface; capture prior sleep setting; restore on every normal exit; detect/recover stale privileged state; explicit battery policy; optional min-battery cutoff; document IOKit-assertion vs global-sleep-policy distinction.

---

## M6 — Later: menu-bar companion · `deferred`

Only after the CLI is mature. Depends on `GuaranateCore`, not the CLI exe.
Small: visualize + control sessions (list, stop/extend, remaining-time,
notifications). No trigger engine. Refs: spec "Future menu-bar companion".

---

## DIST — Distribution · `todo`

Refs: spec "Distribution".

- [x] `DIST-T1` Homebrew tap (`brew tap ryok90/guaranate`); consider `homebrew/core` when mature.
- [x] `DIST-T2` GitHub Releases: tagged, tested, built binaries (`arm64` + `x86_64` or universal), checksums.
- [ ] `DIST-T3` Release automation: test → build → package → checksums → publish → update tap.
- [ ] `DIST-T4` (Later) npm thin installer/launcher for the native binary — never a Node.js core dependency.

---

## Cross-cutting constraints (apply to every milestone)

Refs: spec "Design principles", "Non-goals".

- CLI first; native first (macOS power APIs, never shell out to `caffeinate`).
- Friendly over compatible: `guaranate 2h`, not `-t 7200`.
- Safe cleanup is non-negotiable: signals, crashes, expired leases, child
  failures must never leave a stale assertion; privileged sleep-policy changes
  must be restored to their prior value.
- Human output is attractive; machine output is stable.
- Minimal dependencies; keep the binary small and native.
- Separation of concerns: callers decide **when** to inhibit sleep; Guaranate
  owns **how** the assertion is created, tracked, explained, renewed, released.
- Platform: macOS 14+; Apple Silicon primary, Intel where cheap. Do not
  compromise architecture for Intel.

### Explicit non-goals

No Amphetamine-style GUI breadth or trigger engine; no per-harness
(Claude/Codex/OpenCode/Gemini) behavior; no AI-activity detection; not a
replacement for macOS power management; no silent lid-close override in normal
sessions; not cross-platform; no Node.js core dependency; never wrap
`/usr/bin/caffeinate`.

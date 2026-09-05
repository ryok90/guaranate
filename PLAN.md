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
| M2 | v0.2 — Process lifecycle (`while`, `until`) | in-progress | M1 |
| M3 | v0.3 — Observability & machine output | todo | M2 |
| M4 | v0.4 — External leases | todo | M3 |
| M5 | v0.5 — Power modes, closed-lid, deeper observability | todo | M4 |
| M6 | Later — Menu-bar companion | deferred | M4 |
| DIST | Distribution (Homebrew, GitHub Releases, npm) | todo | M1 |
| DOCS | Documentation website (Astro Starlight + Zephyr Cloud) | in-progress | M1 |

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

## M2 — v0.2 Process lifecycle · `in-progress`

Goal: make `guaranate while <cmd>` a signature, polished workflow; add `until`
and watching an already-running process.
Refs: spec "Flagship workflow", "Keep awake while an existing process runs",
"v0.2", "Process model" (in-process case).

- [x] `M2-T1` `ChildProcess` abstraction in `GuaranateCore`.
  - Acceptance: launch a command with argv; observe exit; testable without a real long-running process.
  - Shipped as `ChildLaunching` (protocol) + `ChildProcess` (`posix_spawnp`), with
    `CommandInvocation` and `ExitStatus` as pure, separately-testable pieces.
    Foundation `Process` was rejected: it always sets `POSIX_SPAWN_SETPGROUP`, so
    the child lands in its own process group where a terminal Ctrl+C never reaches
    it, and it never exposes the raw wait status needed to tell `exit(9)` from
    death by `SIGKILL`.
  - Refs: `Sources/GuaranateCore/Process/*`.
- [x] `M2-T2` `while` command: acquire → launch child → hold for child lifetime → release on exit.
  - Acceptance: `guaranate while sleep 30` holds the assertion for exactly the child's lifetime.
  - Note: `--` is now optional (`guaranate while sleep 30`), accepted, and
    stripped when present.
  - Refs: `Sources/GuaranateCLI/Commands/WhileCommand.swift`, `Sources/GuaranateCLI/ProcessSession.swift`.
- [x] `M2-T3` Signal forwarding to the child (SIGINT/SIGTERM/SIGHUP).
  - Acceptance: Ctrl+C reaches the child; child is not orphaned; parent waits for child teardown.
  - The child also needs its inherited dispositions reset: the parent sets these
    signals to `SIG_IGN` so its dispatch sources are the sole handlers, and
    `SIG_IGN` survives `exec` — without `POSIX_SPAWN_SETSIGDEF` the child would be
    silently immune to Ctrl+C. Covered by a unit test.
- [x] `M2-T4` Child exit-code propagation.
  - Acceptance: `guaranate while sh -c 'exit 7'` exits 7; signal-terminated child maps to 128+signal.
  - Also: command not found exits 127, command not executable exits 126.
- [x] `M2-T5` Guaranteed assertion release on every `while` exit path.
  - Acceptance: normal exit, child crash, and Ctrl+C all leave no stale assertion.
  - Refs: `scripts/smoke.sh` tests 3–5.
- [x] `M2-T6` `while` session output + completion summary.
  - Amended: the original acceptance called for a live redrawn frame (Command,
    Elapsed, Remaining = "process lifetime", …). That is unachievable without
    corrupting the terminal, because the command owns stdout — and a command using
    its own alt-screen or progress bar would fight the frame unfixably. `while`
    therefore passes the terminal through and bookends it with one start line and
    a completion summary. The live frame is kept for watch sessions, where nothing
    else writes to the terminal.
  - Acceptance: the command's output is untouched; the summary names the command,
    its outcome, and the elapsed time; degrades off-TTY.
- [x] `M2-T7` `--reason` on `while`.
  - Acceptance: reason recorded on the assertion; defaults to `while: <command>`
    when omitted.
- [ ] `M2-T8` `until <HH:MM>` command.
  - Acceptance: computes duration to next occurrence of local time; passed-time behavior documented AND tested.
  - Refs: spec "Run until a clock time".
- [~] `M2-T9` Tests: child monitoring, signal forwarding, exit-code propagation, `until` calculation.
  - Shipped: exit-status decoding, argv normalization, `PATH` resolution, 127/126
    launch failures, inherited-`SIG_IGN` reset, process-group inheritance, process
    identity and pid-reuse detection, plus `scripts/smoke.sh` tests 3–8 against the
    real binary. Remaining: `until` calculation (blocked on `M2-T8`).
- [x] `M2-T10` Hold the assertion until an already-running process exits.
  - Shipped as an option, `guaranate -w <pid>` / `--watch <pid>`, not the
    `watch <pid>` subcommand this task originally specified. #17 had rejected
    `-w`-style parity; the reconciliation is that the capability is named
    `--watch` (understandable terminology, per the spec's own preference over
    one-letter compatibility flags) and `AGENTS.md`'s mandatory short-alias rule
    independently makes its short `-w`. `caffeinate -w 1234` therefore ports
    directly without adopting compatibility as a goal.
  - Acceptance: acquires on start and releases exactly when the pid exits
    (`DispatchSourceProcess`/kqueue `NOTE_EXIT`, not polling); an unused pid is
    rejected without acquiring; Ctrl+C releases and detaches without killing the
    watched process; no stale assertion on any exit path; accepts `--reason`.
  - Beyond the original acceptance: plain `NOTE_EXIT` is requested and never
    `NOTE_EXITSTATUS`, because the kernel only enforces credentials when both are
    set — so processes owned by other users can be watched. A `kill(pid, 0)`
    pre-check is mandatory, not polish: libdispatch synthesizes a fake exit event
    when registration fails with `ESRCH`, so an unused pid would otherwise report
    "exited" and exit 0. Sessions bind to the `(pid, start-time)` pair so a
    recycled pid cannot inherit the assertion, and the assertion carries
    `kIOPMAssertionOnBehalfOfPID` so `pmset` names the watched process.
  - Refs: `Sources/GuaranateCore/Process/ProcessIdentity.swift`,
    `Sources/GuaranateCLI/TimedSession.swift`, #33.

Design note: the bare-duration root command and subcommands now coexist via a
`run` default subcommand. A root command that owns a positional argument cannot
gain subcommands — `parsePositionalValues` runs before subcommand dispatch and has
no subcommand awareness, so the positional silently swallows the subcommand name
and makes it unreachable, with no compile-time or runtime diagnostic. The root is
therefore a pure container, and `-v`/`--version` moved onto `run` because a root
with a default subcommand never runs its own `run()`.

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

## DOCS — Documentation website · `in-progress`

Goal: a user-facing docs site that cannot drift from the shipped binary, living
in this repository as a self-contained `docs-website/` package (no root `package.json`,
no monorepo tooling). Refs: #24, `AGENTS.md` "Changelog workflow" /
"Verification", spec "Core user-facing features".

- [x] `DOCS-T1` Astro Starlight site under `docs-website/`, self-contained.
  - Acceptance: `npm run build` in `docs-website/` produces a static site; the
    repository root has no `package.json`; `swift build -c release` and `swift test`
    are unaffected by the presence of `docs-website/`.
  - Refs: `docs-website/package.json`, `docs-website/astro.config.mjs`.
- [x] `DOCS-T2` CLI reference generated from the binary, not hand-maintained.
  - Acceptance: `docs-website/scripts/gen-cli-reference.mjs` renders
    `docs-website/src/content/docs/reference/cli.md` from
    `guaranate --experimental-dump-help`; `--check` mode fails on a stale page and
    runs in the macOS `Build & Test` job, so every documented flag and short alias
    matches the shipped binary.
  - Refs: `docs-website/scripts/gen-cli-reference.mjs`, `.github/workflows/ci.yml`.
- [x] `DOCS-T3` Zephyr Cloud deployment wired into the docs build.
  - Acceptance: `withZephyr()` in the Astro config with `output: 'static'`;
    `.github/workflows/docs.yml` deploys `main` and internal PRs with `ZE_CI_TOKEN`
    + `ZE_FAIL_BUILD=true` (a deploy or plugin error fails the job) and
    build-verifies fork PRs without a token; internal PRs surface the preview URL.
  - Refs: `.github/workflows/docs.yml`, `docs-website/README.md`.
- [x] `DOCS-T4` CI path split between Swift and docs.
  - Acceptance: a docs-only PR does not run the Swift build/test/smoke job; a
    Swift-only PR does not run the docs job.
  - Refs: `.github/workflows/ci.yml`, `.github/workflows/docs.yml`.
- [x] `DOCS-T5` v0.1 content: landing, install, sessions, how-it-works, roadmap.
  - Acceptance: no page advertises an unshipped command; planned surface is
    confined to the roadmap page and marked as planned; `GUARANATE.md`, `PLAN.md`,
    and `AGENTS.md` stay root-internal and are not duplicated into `docs-website/`.
- [x] `DOCS-T6` Canonical domain and Zephyr environment wiring.
  - Acceptance: the production domain https://guaranate.dev is attached via
    Zephyr Tags & Environments, the Astro config defaults `site` to it (enabling
    canonical URLs and the sitemap, with `DOCS_SITE_URL` still overriding), and
    `README.md` links the live site.
  - Refs: `docs-website/astro.config.mjs`, https://docs.zephyr-cloud.io/features/tags-environments.
- [-] `DOCS-T7` Docs versioning. Deferred: pre-1.0 there is only one version to
  document.
- [x] `DOCS-T8` Mascot branding across the site and `README.md`.
  - Acceptance: the six variants from the branding sheet are cut to transparent
    PNGs by `docs-website/scripts/gen-brand-assets.sh` and each has exactly one use — site
    logo, landing hero, 404 hero, install guide, sessions guide, and the favicon;
    assets read correctly at favicon size and on both light and dark backgrounds.
  - Refs: `docs-website/scripts/gen-brand-assets.sh`, `docs-website/src/assets/brand/`,
    `docs-website/public/brand/`, #24.
- [x] `DOCS-T9` Visual identity: brand palette, type, and navigation to the docs.
  - Acceptance: Starlight's grey and accent ramps are rotated to warm neutrals and
    the mascot's berry red, with aside/card accents in leaf green and guaraná amber;
    Space Grotesk and JetBrains Mono are self-hosted (no font-CDN requests); hero
    images render uncropped; the landing page offers a "Read the docs" primary
    action and a "Where to next" card grid, not just an install link. Verified in
    both light and dark themes.
  - Refs: `docs-website/src/styles/theme.css`, `docs-website/src/content/docs/index.mdx`.

- [x] `DOCS-T10` Split published docs from contributor/agent docs.
  - Acceptance: the Astro site lives in `docs-website/` and `docs/` holds
    contributor- and agent-facing documentation only (`docs/agents/` skill
    configuration, `docs/adr/` decision records); every path reference — CI
    workflows, `.gitignore`, the Starlight edit link, the generator scripts,
    `README.md`, `AGENTS.md` — points at the new location, and `npm run build`
    plus `npm run gen:cli:check` still pass from `docs-website/`.
  - Refs: `docs/agents/`, `.github/workflows/docs.yml`, `.github/workflows/ci.yml`.

- [ ] `DOCS-T11` Docs deployment rides along with the release.
  - Acceptance: a `v*` release deploys the docs built from that exact tag to the
    production Zephyr environment after the binary is published; a failed release
    does not deploy docs; the Zephyr token/env logic lives in one reusable
    workflow shared by `docs.yml` and `release.yml`.
  - Refs: #31, `.github/workflows/release.yml`, `.github/workflows/docs.yml`.
- [ ] `DOCS-T12` Dispatchable docs-only deployment.
  - Acceptance: `workflow_dispatch` takes a `ref` (branch or tag, default `main`)
    and an explicit production-or-preview target, and deploys only the docs — no
    tag, no release; fork PRs still build-verify without a token.
  - Refs: #31, `.github/workflows/docs.yml`.

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

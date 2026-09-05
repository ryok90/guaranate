# Guaranate

> A developer-friendly macOS keep-awake CLI.

Guaranate is a small, native macOS command-line utility for managing sleep-prevention sessions with a friendlier, more scriptable interface than `caffeinate`.

The project takes inspiration from Apple's open-source `caffeinate` implementation and macOS power-management behavior, but **does not wrap `caffeinate`**. Guaranate should use the native macOS power-management APIs directly.

The name is a play on **guaraná**, the Brazilian stimulant, and Apple's `caffeinate` command.

---

## Product position

Guaranate should not try to compete with GUI-first tools such as Amphetamine by reproducing a large trigger system, extensive preference panes, or a broad consumer-facing feature set.

Its niche is narrower:

> **A native macOS power-management primitive for developers, scripts, and automation.**

The CLI is the product. A future menu-bar interface may exist as a lightweight companion, but it should not define the architecture or roadmap.

Guaranate should differentiate through:

- excellent terminal ergonomics;
- human-readable durations;
- first-class process lifecycle handling;
- machine-readable output;
- explicit lease semantics for external software;
- safe TTL-based cleanup;
- clear visibility into why the Mac is being kept awake;
- direct native integration with macOS power APIs.

---

## Product goals

Guaranate should provide:

- A simple, human-friendly way to keep macOS awake for a duration.
- Direct use of the native macOS power assertion APIs.
- Clear terminal feedback showing elapsed and remaining time.
- Human-readable durations such as `30m`, `2h`, and `1h30m`.
- A **first-class** mechanism for keeping the system awake while another command runs.
- Correct child-process lifecycle and exit-code propagation.
- Visibility into active Guaranate sessions and, where practical, relevant macOS power assertions.
- Stable machine-readable output for automation.
- A generic lease-style CLI contract that other tools can use to acquire, renew, and release sleep-prevention assertions.
- A reusable core architecture that could later support a native menu-bar companion.

Guaranate should remain a focused Unix-style utility rather than becoming a general-purpose macOS automation suite.

---

## Initial scope

The first releases should be **CLI-only**.

Harness-specific integrations for tools such as Claude Code, Codex, OpenCode, Gemini CLI, or others are **out of scope initially**. Instead, Guaranate should expose generic primitives that tools, plugins, hooks, scripts, or wrappers can use.

Guaranate should also **not** initially implement Amphetamine-style trigger rules such as:

- external-display detection;
- Wi-Fi/VPN state;
- USB/Bluetooth device state;
- CPU thresholds;
- application detection;
- power-adapter policies;
- mounted-volume rules.

Those decisions should remain the responsibility of the caller.

Guaranate's job is to manage the power assertion safely once a caller decides that work must continue.

---

## Recommended stack

### Language

**Swift 6**

Reasons:

- Guaranate is intentionally macOS-specific.
- Swift has direct access to macOS frameworks and IOKit.
- It produces a native executable with no Node.js or other runtime dependency.
- It is suitable for both a CLI and a future SwiftUI menu-bar application.
- It allows the core power-management implementation to be shared between CLI and GUI targets.

### Build system

**Swift Package Manager**

Use SwiftPM for:

- dependency management;
- builds;
- tests;
- executable targets;
- reusable library targets.

### CLI parsing

**Swift Argument Parser**

Use Apple's `swift-argument-parser` package for:

- commands;
- subcommands;
- flags;
- options;
- generated help;
- validation;
- shell completion support.

### Power management

Use the native macOS power-management APIs directly, primarily through IOKit.

Relevant APIs include the `IOPMAssertion*` family, such as:

- `IOPMAssertionCreateWithName`
- `IOPMAssertionCreateWithProperties`
- `IOPMAssertionRelease`

The implementation should use the appropriate assertion types for the requested behavior.

Apple's open-source `caffeinate.c` should be treated as a **reference implementation** for:

- assertion semantics;
- mapping user intentions to power assertion types;
- process-lifetime behavior;
- timeout behavior;
- cleanup and signal handling;
- other useful implementation details.

Guaranate should not invoke `/usr/bin/caffeinate` as its implementation mechanism.

It should also avoid copying significant portions of Apple's source. Reimplement the desired behavior using the public macOS APIs.

### Terminal rendering

Initially use lightweight ANSI terminal control rather than adding a full terminal UI framework.

Timed session:

```text
🌿 Guaranate

Elapsed      00:42:17
Remaining    01:17:43
Ends         23:43
Assertion    System sleep
Display      May sleep

Press Ctrl+C to stop
```

Process sessions do not get a live frame. The command owns the terminal — its
output, input, and exit code pass straight through — so Guaranate announces the
session in one line, stays out of the way, and reports the outcome when the
command exits:

```text
🌿 Guaranate — staying awake while pnpm build runs · System sleep, display may sleep
<the command's own output, untouched>
✓ pnpm build finished after 47m 12s
✓ Sleep-prevention assertion released
```

Watching an already-running process does get the live frame, because nothing
else is writing to the terminal:

```text
🌿 Guaranate

⠹ Awake — until the watched process exits

Elapsed      00:42:17
Watching     4821 (node)
Assertion    System sleep
Display      May sleep

Press Ctrl+C or q to stop
```

Terminal behavior should degrade cleanly when stdout is not a TTY.

### Machine-readable output

Every command that exposes useful state should be designed with automation in mind.

Prefer common flags such as:

```bash
--json
--quiet
```

Examples:

```bash
guaranate status --json
guaranate acquire --ttl 5m --json
```

Do not make scripts parse decorated terminal output.

### Testing

Use Swift's standard testing tools.

Prioritize tests for:

- duration parsing;
- time calculations;
- command parsing;
- lifecycle state;
- lease expiration;
- child-process monitoring;
- signal forwarding;
- exit-code propagation;
- JSON output;
- power-assertion abstraction behavior.

Native IOKit interactions should sit behind a protocol or abstraction so most behavior can be tested without actually changing the test machine's sleep state.

---

## Platform support

Target macOS only.

Preferred release support:

- Apple Silicon (`arm64`)
- Intel (`x86_64`) where the maintenance and build overhead remains small

The project should aim to publish a universal or equivalent dual-architecture release if Swift, the chosen deployment target, and the required IOKit APIs make this straightforward.

If supporting Intel creates meaningful complexity later, Apple Silicon may become the primary supported architecture.

Do not compromise the internal architecture merely to retain Intel compatibility.

A reasonable initial deployment target is **macOS 14+**, subject to confirming that all required APIs and Swift runtime behavior work cleanly across the supported architectures.

---

# Core user-facing features

## Timed sessions

Human-readable duration:

```bash
guaranate 30m
guaranate 2h
guaranate 1h30m
guaranate 90s
```

While active, Guaranate should:

- acquire the requested macOS power assertion;
- show elapsed time;
- show remaining time;
- show the calculated end time;
- release the assertion on completion;
- release the assertion on Ctrl+C or normal termination.

Plain integer input may optionally be interpreted as seconds for compatibility with `caffeinate`-style usage:

```bash
guaranate 3600
```

---

## Run until a clock time

```bash
guaranate until 18:00
```

Guaranate should calculate the duration relative to the current local time and keep the requested assertion until then.

Behavior around times already passed should be explicit and predictable.

The first implementation can interpret a passed time as the next occurrence on the same/next calendar day, but the chosen behavior must be documented and tested.

---

# Flagship workflow: keep awake while a command runs

```bash
guaranate while pnpm build
guaranate while ./long-running-task.sh
guaranate while rsync ...
guaranate while ffmpeg ...
guaranate while ssh ...
```

A `--` separator is accepted and optional; it is only needed when the command's
own first argument could be mistaken for one of Guaranate's flags.

This should be treated as a **flagship feature**, not a small convenience wrapper.

Behavior:

1. Acquire the requested assertion.
2. Launch the child process, which inherits Guaranate's standard streams and
   process group so it behaves exactly as it would if run directly.
3. Keep the assertion for the lifetime of the child process.
4. Forward relevant signals, and wait for the child to finish terminating before
   releasing the assertion — a command must never keep running against a machine
   that has already been allowed to sleep.
5. Release the assertion when the child process exits.
6. Exit with the child's exit code, or `128 + signal` when a signal killed it.
   A command that cannot be found exits 127; one that cannot be executed exits
   126, matching every POSIX shell.
7. Never leave a stale assertion behind.

Example:

```text
$ guaranate while pnpm build
🌿 Guaranate — staying awake while pnpm build runs · System sleep, display may sleep
<pnpm build's own output>
```

When the command exits:

```text
✓ pnpm build finished after 47m 12s
✓ Sleep-prevention assertion released
```

Potential later options:

```bash
guaranate while --notify pnpm build
```

The first release does not need notifications, but the command lifecycle should be designed cleanly enough to support them later.

---

# Keep awake while an existing process runs

```bash
guaranate --watch 4821
guaranate -w 4821
```

`while` only guards processes Guaranate launches. Plenty of long-running work is
already running by the time someone realizes the Mac will fall asleep under it,
so Guaranate should also be able to attach to an existing process id.

Behavior:

1. Acquire the requested assertion.
2. Hold it until the named process exits, then release and exit 0.
3. Only observe: never start, signal, or kill the watched process. Interrupting
   Guaranate detaches from it and leaves it running.
4. Refuse a process id that is not in use, rather than silently succeeding.
5. Survive process-id reuse: a recycled id must never inherit the assertion.

A process belonging to another user can be watched, and the assertion should be
attributed to the watched process so that system tools name the process the Mac
is being kept awake for.

---

# Observability

## Status

```bash
guaranate status
```

Initially, `status` should report Guaranate-managed sessions.

```text
🌿 Guaranate

2 active sessions

ID       CREATED BY        MODE      ELAPSED    REMAINING
7AE42C   pnpm build        system    00:38:12   process
04DF21   external lease    system    00:01:42   03:18

Display sleep       allowed
Idle system sleep   prevented
```

Machine-readable equivalent:

```bash
guaranate status --json
```

Example:

```json
{
  "sleepPrevented": true,
  "displaySleepPrevented": false,
  "sessions": [
    {
      "id": "7AE42C",
      "reason": "pnpm build",
      "kind": "process",
      "elapsedSeconds": 2292
    }
  ]
}
```

A future version may inspect relevant power assertions created by other processes where macOS exposes enough reliable information.

## Why

```bash
guaranate why
```

This command should answer the user's real question:

> Why is my Mac being kept awake?

Example:

```text
Your Mac is being kept awake.

Reason:
  pnpm build is still running

Started:
  38 minutes ago

Display:
  May sleep normally
```

Long-term:

```bash
guaranate why --all
```

may explain relevant system-wide assertions, including those not created by Guaranate, if the underlying macOS APIs provide sufficiently reliable data.

This observability should be considered a meaningful product differentiator.

---

# Assertion modes

The default behavior should correspond to preventing **user-idle system sleep** while still allowing the display to sleep.

This is the normal desired mode for:

- builds;
- downloads;
- long-running CLI tasks;
- AI coding agents;
- unattended compute that does not need the screen.

Future or early optional flags may expose additional assertion types.

Possible interface:

```bash
guaranate 2h
guaranate 2h --display
guaranate 2h --system
```

Exact naming should be chosen based on the native assertion semantics rather than blindly copying `caffeinate` flags.

The CLI should favor understandable terminology over one-letter compatibility flags.

---

# External tool API

Guaranate should provide a generic CLI interface that external tools can use without Guaranate knowing anything about the caller.

This is intended for:

- AI coding harnesses;
- plugins;
- editor extensions;
- build systems;
- automation tools;
- scripts;
- backup tools;
- download tools;
- any process with a known active-work lifecycle.

The API should be generic and should not require the caller to identify itself as an AI tool.

## Acquire

```bash
guaranate acquire \
  --reason "Background agent turn" \
  --ttl 5m
```

Expected output:

```text
F82A91
```

With machine-readable output:

```bash
guaranate acquire \
  --reason "Background agent turn" \
  --ttl 5m \
  --json
```

Example:

```json
{
  "id": "F82A91",
  "expiresAt": "2026-08-21T02:15:00Z",
  "type": "idle",
  "reason": "OpenCode active turn"
}
```

The caller should not be required to identify itself as an AI tool.

---

## Renew

```bash
guaranate renew F82A91 --ttl 5m
```

This extends the lease.

A lease-based model is preferred for external integrations because it provides failure safety.

If the calling tool crashes and stops renewing the lease, Guaranate should eventually release the assertion rather than leaving the machine awake indefinitely.

---

## Release

```bash
guaranate release F82A91
```

Explicitly releases the assertion.

This should be idempotent where practical.

---

## Lease design

Externally-created assertions should support TTLs.

Conceptually:

```text
tool starts active work
        │
        ▼
guaranate acquire --ttl 5m
        │
        ├── work
        │
        ├── renew
        │
        ├── work
        │
        ├── renew
        │
        ▼
tool finishes
        │
        ▼
guaranate release
```

If the tool crashes:

```text
tool crashes
    │
    X
    │
lease reaches TTL
    │
    ▼
Guaranate releases assertion
```

This prevents stale sleep inhibitors.

---

# Process model

The simplest interactive commands can hold an IOKit assertion directly within the running Guaranate process.

Examples:

```bash
guaranate 2h
guaranate while -- pnpm build
```

For external `acquire / renew / release` leases, Guaranate will need state that survives the invocation that created the lease.

The implementation should therefore be designed with a lightweight background session manager in mind.

Possible architecture:

```text
                guaranate CLI
                     │
          ┌──────────┼──────────┐
          │          │          │
       timed       while     acquire/
       session     command    renew/
                              release
                                  │
                                  ▼
                         Guaranate session
                             manager
                                  │
                                  ▼
                              IOKit
                                  │
                                  ▼
                           macOS powerd
```

The exact IPC mechanism can be selected during implementation.

Candidates include:

- Unix domain socket;
- XPC;
- a lightweight local daemon;
- another native macOS IPC mechanism.

For v0.1, avoid overengineering the daemon unless `acquire / renew / release` requires it immediately.

The external lease API is part of the desired initial product surface, so the chosen implementation must support independent CLI invocations reliably.

---

# Suggested project structure

```text
Guaranate/
├── Package.swift
│
├── Sources/
│   ├── GuaranateCLI/
│   │   ├── Guaranate.swift
│   │   ├── Commands/
│   │   │   ├── TimedCommand.swift
│   │   │   ├── UntilCommand.swift
│   │   │   ├── WhileCommand.swift
│   │   │   ├── StatusCommand.swift
│   │   │   ├── WhyCommand.swift
│   │   │   ├── AcquireCommand.swift
│   │   │   ├── RenewCommand.swift
│   │   │   └── ReleaseCommand.swift
│   │   └── Output/
│   │       ├── TerminalRenderer.swift
│   │       └── JSONRenderer.swift
│   │
│   ├── GuaranateCore/
│   │   ├── Power/
│   │   │   ├── PowerAssertion.swift
│   │   │   ├── PowerAssertionType.swift
│   │   │   └── PowerManager.swift
│   │   ├── Sessions/
│   │   │   ├── Session.swift
│   │   │   ├── SessionID.swift
│   │   │   ├── SessionManager.swift
│   │   │   └── Lease.swift
│   │   ├── Time/
│   │   │   ├── DurationParser.swift
│   │   │   └── Deadline.swift
│   │   └── Process/
│   │       └── ChildProcess.swift
│   │
│   └── GuaranateService/
│       ├── Service.swift
│       └── IPC/
│
└── Tests/
    ├── GuaranateCoreTests/
    └── GuaranateCLITests/
```

The exact layout can evolve, but the important architectural boundary is:

```text
CLI/UI
  │
  ▼
GuaranateCore
  │
  ▼
macOS power APIs
```

A future menu-bar application should depend on `GuaranateCore` rather than the CLI executable.

---

# Future menu-bar companion

A menu-bar interface is **not part of the core roadmap** and should come only after the CLI is mature.

If built, it should be intentionally small.

Its purpose would be to visualize and control Guaranate sessions, not to recreate Amphetamine.

Example:

```text
🌿 Guaranate
────────────────────────

Active sessions: 2

● pnpm build
  38m elapsed

● Background task
  3m remaining

[ Stop All ]

────────────────────────

System sleep prevented
Display sleep allowed
```

Potential companion features:

- menu-bar remaining-time indicator;
- list of active Guaranate sessions;
- stop/extend actions;
- lightweight status visualization;
- notifications.

Avoid adding a large GUI trigger engine unless future user demand clearly justifies it.

---

# Distribution

## Primary

**Homebrew**

Initial installation should use a project-owned tap:

```bash
brew tap <owner>/guaranate
brew install guaranate
```

Once the project is mature and meets Homebrew requirements, consider submitting it to `homebrew/core`.

---

## GitHub Releases

Tagged releases should publish compiled artifacts for supported architectures.

Preferred:

```text
guaranate-macos-arm64.tar.gz
guaranate-macos-x86_64.tar.gz
```

or a universal binary when practical.

Release automation should:

1. run tests;
2. build release binaries;
3. package artifacts;
4. create GitHub checksums;
5. publish the GitHub Release;
6. update the Homebrew tap.

---

## npm

Do **not** use npm as the initial implementation or primary distribution mechanism.

A future npm package may act as a thin installer/launcher for the native Guaranate binary:

```bash
npm install -g guaranate
```

or:

```bash
npx guaranate 2h
```

This should be considered a distribution convenience for developer-heavy audiences, not a reason to introduce Node.js into the core application.

---

# Licensing

Recommended project license:

**MIT**

Keep Guaranate's implementation original.

Apple's open-source `caffeinate` source can be studied to understand expected behavior and native power-management usage, but avoid copying implementation code into Guaranate.

Document the Apple implementation as an engineering reference rather than a code dependency.

---

# Revised release roadmap

## v0.1 — Native CLI foundation

Implement:

- direct IOKit power assertions;
- `guaranate <duration>`;
- human-readable durations;
- elapsed timer;
- remaining timer;
- end time;
- Ctrl+C / signal cleanup;
- non-TTY-friendly output;
- Swift Argument Parser;
- core unit tests.

First milestone:

```bash
guaranate 10m
```

must be robust before expanding the surface.

---

## v0.2 — Process lifecycle

Make `while` excellent:

```bash
guaranate while -- pnpm build
```

Implement:

- child-process launch;
- signal forwarding;
- elapsed time;
- process-lifetime assertion;
- guaranteed cleanup;
- child exit-code propagation;
- optional `--reason`.

Also add:

```bash
guaranate until 18:00
```

---

## v0.3 — Observability and machine output

Add:

```bash
guaranate status
guaranate status --json
guaranate why
```

Also establish common automation behavior:

```bash
--json
--quiet
```

Where useful, define stable exit codes for scripting.

---

## v0.4 — External leases

Add:

```bash
guaranate acquire
guaranate renew
guaranate release
```

Including:

- TTLs;
- reasons;
- JSON output;
- persistent session state;
- the minimal background service/IPC required to make leases reliable.

This becomes the stable integration surface for external software and AI harnesses.

---

## v0.5 — Power modes, closed-lid support, and deeper observability

Expand:

- assertion type options;
- better inspection of active assertions;
- clearer `status`;
- clearer `why`;
- possible `why --all`;
- structured machine-readable status;
- shell completions.

Investigate whether Guaranate can reliably explain relevant assertions created by other macOS processes.


Also prototype explicit privileged closed-lid support:

```bash
guaranate 2h --clamshell
guaranate while --clamshell -- <command>
```

Requirements before the feature is considered stable:

- isolate administrator privileges to the smallest possible surface;
- capture the previous macOS sleep setting before modification;
- restore the previous setting on every normal exit path;
- detect and recover stale privileged state;
- require an explicit battery policy;
- support an optional minimum-battery cutoff;
- clearly document the distinction between IOKit assertions and global sleep-policy changes.

---

## Later — Lightweight menu-bar companion

Only after the CLI is mature.

The GUI should visualize and control Guaranate sessions rather than become a trigger-heavy standalone keep-awake product.

---

# Non-goals

Guaranate is not intended to:

- compete with Amphetamine on GUI breadth;
- implement a large condition/trigger engine;
- implement Claude Code-specific behavior;
- implement Codex-specific behavior;
- implement OpenCode-specific behavior;
- implement Gemini-specific behavior;
- detect whether an AI agent is currently thinking;
- replace macOS power management;
- silently override lid-close behavior as part of normal sessions;
- disable every form of system sleep;
- become a cross-platform utility;
- depend on Node.js;
- wrap `/usr/bin/caffeinate`.

External tools should decide **when** work requires the Mac to remain awake.

Guaranate should provide a safe, observable, scriptable way to manage the corresponding native power assertion.

---

# Design principles

## CLI first

The terminal interface is the primary product, not a secondary control surface.

## Native first

Prefer native macOS APIs over shelling out to system utilities.

## Friendly over compatible

Guaranate does not need to reproduce `caffeinate`'s CLI syntax.

Prefer:

```bash
guaranate 2h
```

over:

```bash
guaranate -t 7200
```

## Process lifecycle is first-class

`guaranate while -- <command>` should feel polished enough to become a signature workflow.

## Safe cleanup

A power assertion must never remain active accidentally because Guaranate failed to clean up.

Signals, crashes, expired leases, and child-process failures must all be considered.

Privileged closed-lid mode has an even stronger requirement: any system-wide sleep-policy value modified by Guaranate must be restored to the value that existed before the session began.

## Human and machine interfaces

Interactive commands should have attractive terminal output.

Automation should have stable machine-readable output.

## Observability matters

Users should be able to answer:

```bash
guaranate status
guaranate why
```

without understanding IOKit or `pmset` internals.

## Minimal dependencies

Keep the binary small and native.

Add dependencies only when they materially improve maintainability.

## Separation of concerns

External tools decide **when** to inhibit sleep.

Guaranate owns **how** the assertion is created, tracked, explained, renewed, and released.

---

# Product identity

**Name:** Guaranate

**Command:**

```bash
guaranate
```

Primary positioning:

> A developer-friendly macOS keep-awake CLI.

Alternative tagline:

> Keep your Mac awake when work needs to finish.

Playful copy:

> Give your Mac some guaraná.

The product should use ASCII `guaranate` for:

- executable names;
- repository names;
- Homebrew formula names;
- package identifiers;
- URLs.

Visual branding may use the properly accented word **guaraná** where appropriate.

---

# Bootstrap target

The first engineering milestone should be small:

```bash
swift run guaranate 10m
```

should:

1. parse `10m`;
2. acquire a native `PreventUserIdleSystemSleep` assertion;
3. show elapsed and remaining time;
4. allow the display to sleep;
5. release the assertion automatically after ten minutes;
6. release it immediately on Ctrl+C;
7. leave no stale assertion behind.

The second engineering milestone should validate the strongest developer workflow:

```bash
swift run guaranate while -- sleep 30
```

should:

1. acquire the assertion;
2. launch the child process;
3. show elapsed time;
4. forward termination correctly;
5. release the assertion when the child exits;
6. return the child's exit code.

Once those two behaviors are robust, build observability and the external lease API on top of the same core abstractions.

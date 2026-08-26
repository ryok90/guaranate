# 🌿 Guaranate

> A developer-friendly macOS keep-awake CLI.

Guaranate is a small, native macOS command-line utility for managing
sleep-prevention sessions with a friendlier, more scriptable interface than
`caffeinate`.

It talks to the native macOS power-management APIs (IOKit `IOPMAssertion*`)
directly. It **does not** wrap `/usr/bin/caffeinate`.

The name is a play on **guaraná**, the Brazilian stimulant, and Apple's
`caffeinate` command.

> Keep your Mac awake when work needs to finish. Give your Mac some guaraná.

---

## Status

**v0.1 — native CLI foundation.** Timed sessions work end-to-end. The broader
surface (`while`, `until`, `status`, `why`, external leases) is planned and
tracked in [`PLAN.md`](PLAN.md).

| Feature | State |
| --- | --- |
| `guaranate <duration>` timed session | ✅ shipped |
| Native `IOPMAssertion` (no `caffeinate`) | ✅ shipped |
| Elapsed / remaining / end-time display | ✅ shipped |
| Ctrl+C / SIGTERM cleanup, no stale assertion | ✅ shipped |
| Non-TTY-friendly output | ✅ shipped |
| `guaranate while -- <cmd>` | 🔜 v0.2 |
| `guaranate until <HH:MM>` | 🔜 v0.2 |
| `status` / `why` / `--json` | 🔜 v0.3 |
| `acquire` / `renew` / `release` leases | 🔜 v0.4 |

---

## Install

### From source

Requires Swift 6 (Xcode 16+) on macOS 14 or later.

```bash
git clone git@github.com:ryok90/guaranate.git
cd guaranate
swift build -c release
cp .build/release/guaranate /usr/local/bin/   # or anywhere on your PATH
```

Homebrew and GitHub Release binaries are planned; see [`PLAN.md`](PLAN.md).

---

## Usage

Keep the Mac awake for a human-readable duration:

```bash
guaranate 30m
guaranate 2h
guaranate 1h30m
guaranate 90s
guaranate 3600      # a bare integer is interpreted as seconds
```

While active, Guaranate acquires a power assertion and shows a live frame:

```text
🌿 Guaranate

Elapsed      00:42:17
Remaining    01:17:43
Ends         23:43:07
Assertion    System sleep
Display      May sleep

Press Ctrl+C to stop
```

The assertion is released automatically when the duration elapses, on Ctrl+C,
or on `SIGTERM` — never leaving a stale sleep inhibitor behind.

### Assertion modes

The default prevents **user-idle system sleep** while still letting the display
sleep — the right mode for builds, downloads, and unattended compute.

```bash
guaranate 2h              # prevent idle system sleep (display may sleep)
guaranate 2h --display    # also keep the display awake
guaranate 2h --system     # prevent all system sleep
```

### Options

| Option | Description |
| --- | --- |
| `--display` | Also keep the display awake. |
| `--system` | Prevent all system sleep. |
| `--reason <text>` | Reason recorded on the power assertion. |
| `--version` | Print the version. |
| `-h`, `--help` | Show help. |

### Non-interactive output

When stdout is not a TTY (pipes, files, CI), the live frame degrades to a
single start line and a single completion line — no per-second churn.

---

## How it works

Guaranate uses IOKit power assertions directly:

- `IOPMAssertionCreateWithName` to acquire an assertion of the requested type
  (`PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep`, or
  `PreventSystemSleep`);
- `IOPMAssertionRelease` on every exit path.

Apple's open-source `caffeinate.c` is treated only as an engineering reference
for assertion semantics — no Apple implementation code is copied, and
`/usr/bin/caffeinate` is never invoked.

You can confirm a live assertion with:

```bash
pmset -g assertions
```

---

## Architecture

The important boundary is `CLI → GuaranateCore → macOS power APIs`. A future
menu-bar companion would depend on `GuaranateCore`, not the CLI executable.

```text
Sources/
├── GuaranateCLI/            # commands, terminal rendering, process runtime
│   ├── Guaranate.swift      # @main root command
│   ├── TimedSession.swift   # acquire → render loop → guaranteed release
│   └── Output/
│       └── TerminalRenderer.swift
└── GuaranateCore/           # pure, IOKit-free logic (unit-tested)
    ├── Power/               # PowerAsserting protocol + IOKit PowerManager
    └── Time/                # DurationParser, Deadline, TimeFormatting
```

Native IOKit interaction sits behind the `PowerAsserting` protocol, so time,
duration, and (later) lease logic are fully testable without changing the host
machine's sleep state.

---

## Development

```bash
swift build      # build
swift test       # run the unit tests
swift run guaranate 10m
```

See [`CHANGELOG.md`](CHANGELOG.md) for notable changes and
[`AGENTS.md`](AGENTS.md) for repository conventions. Every pull request with
user-facing impact adds an entry under `## [Unreleased]` in `CHANGELOG.md`; CI
enforces this.

---

## License

[MIT](LICENSE). Guaranate's implementation is original.

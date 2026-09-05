---
title: Roadmap
description: What Guaranate ships today and which commands are still planned.
---

Guaranate is pre-1.0. This page is the honest boundary between the two: if a
command is not marked shipped, it does not exist in the binary yet and no guide
on this site documents it as if it did.

Sequencing, task IDs, and acceptance criteria live in
[`PLAN.md`](https://github.com/ryok90/guaranate/blob/main/PLAN.md); product
intent lives in
[`GUARANATE.md`](https://github.com/ryok90/guaranate/blob/main/GUARANATE.md).

## Shipped — v0.1

| Feature | Documented in |
| --- | --- |
| `guaranate <duration>` timed session | [Keeping your Mac awake](/guides/timed-sessions/) |
| `guaranate` with no duration, until interrupted | [Indefinite sessions](/guides/timed-sessions/#indefinite-sessions) |
| Native `IOPMAssertion` — never `caffeinate` | [How it works](/guides/how-it-works/) |
| Assertion modes `--display` / `--system` | [Assertion modes](/guides/timed-sessions/#assertion-modes) |
| `--reason` recorded on the assertion | [Labelling a session](/guides/timed-sessions/#labelling-a-session) |
| Live progress frame, with `q` to quit | [The live frame](/guides/timed-sessions/#the-live-frame) |
| Guaranteed release on expiry, `q`, `SIGINT`, `SIGTERM` | [Ending a session](/guides/timed-sessions/#ending-a-session) |
| Non-TTY-friendly output | [Scripts, pipes, and CI](/guides/timed-sessions/#scripts-pipes-and-ci) |

## Planned

Not yet implemented. Listed so you can tell what is coming — and what to not
reach for today.

| Planned | Target | What it will do |
| --- | --- | --- |
| `guaranate while -- <cmd>` | v0.2 | Hold the assertion for exactly a child command's lifetime, forwarding signals and propagating its exit code. |
| `guaranate until <HH:MM>` | v0.2 | Stay awake until the next occurrence of a clock time. |
| `guaranate watch <pid>` | v0.2 | Hold the assertion until an already-running process exits. |
| `status` / `why` | v0.3 | Explain what is keeping the Mac awake, and since when. |
| `--json` output contract | v0.3 | Stable machine-readable output for scripts. |
| `acquire` / `renew` / `release` | v0.4 | TTL-based leases for external tools, released automatically if a caller stops renewing. |
| Disk-idle mode, `--clamshell` | v0.5 | Broader assertion coverage and prototype closed-lid support. |
| Menu-bar companion | later | Visualize and control sessions from the menu bar. |

## Out of scope

Guaranate is not aiming to become an Amphetamine-style GUI or a trigger engine.
There is no AI-activity detection, no per-tool special-casing, and no
cross-platform support planned — and it will never wrap `/usr/bin/caffeinate`.

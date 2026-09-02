---
title: How it works
description: What Guaranate does to macOS, how to verify a live assertion, and why cleanup is guaranteed.
---

Guaranate is not a wrapper. It creates and releases macOS power assertions itself
through IOKit, so what happens to your Mac is exactly what the assertion API
describes — nothing more.

## Power assertions, not tricks

While a session runs, Guaranate holds one IOKit assertion, created with
`IOPMAssertionCreateWithName` and released with `IOPMAssertionRelease`:

| Session | Assertion type |
| --- | --- |
| default | `PreventUserIdleSystemSleep` |
| `--display` | `PreventUserIdleDisplaySleep` |
| `--system` | `PreventSystemSleep` |

These are the same primitives macOS itself uses when a video player or an
installer keeps your Mac awake. Guaranate never changes a system-wide sleep
setting, never requires `sudo`, and never invokes `/usr/bin/caffeinate`. Apple's
open-source `caffeinate.c` is treated only as an engineering reference for
assertion semantics.

Because it is an assertion and not a policy change, closing the lid still sleeps
the machine, and killing the process — however abruptly — cannot leave your Mac
permanently awake: the kernel drops assertions held by a dead process.

## Verify a live session

`pmset` reports every assertion on the system, including yours. Run a session in
the background and look for your `--reason` text:

```bash
guaranate 60 --reason "check-assertion" &
pmset -g assertions | grep check-assertion
```

While the session is live you'll see the assertion attributed to the `guaranate`
process. After it ends, the same `grep` returns nothing:

```bash
wait $!                                        # session exits 0 at 60s
pmset -g assertions | grep check-assertion || echo "released"
```

`pmset` is a verification aid only — Guaranate does not shell out to it, or to
any other command-line tool, to do its work.

## Cleanup is a guarantee, not a best effort

Sleep inhibition that outlives the thing that needed it is the failure mode that
matters, so every exit path releases the assertion before the process exits:
normal expiry, `q`, Ctrl+C (`SIGINT`), and `SIGTERM`. `SIGINT` and `SIGTERM` are
handled explicitly rather than being left to their default dispositions, so the
release always runs first.

The repository's end-to-end smoke test drives the real binary against the real
API and fails the build if an assertion is ever missing while held, or still
present after exit — including the interrupt path and its `130` exit code.

## Where it fits

Guaranate deliberately does not decide *when* your Mac should stay awake. It has
no trigger engine, no activity detection, and no background daemon watching your
apps. A caller — you, a script, a CI job, a build tool — decides when to inhibit
sleep; Guaranate owns how the assertion is created, explained, and released.

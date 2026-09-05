---
title: Keeping your Mac awake
description: Timed and indefinite Guaranate sessions, duration syntax, assertion modes, and what the live frame shows.
---

A Guaranate session holds a macOS power assertion for as long as it runs, and
releases it when it ends. Everything else — the duration syntax, the assertion
mode, the live frame — is about deciding *how long* and *how much* sleep to
inhibit.

## Timed sessions

Pass a duration and Guaranate stays awake for exactly that long, then exits `0`:

```bash
guaranate 30m
guaranate 2h
guaranate 1h30m
guaranate 90s
guaranate 1d2h
guaranate 3600      # a bare integer is a number of seconds
```

### Duration syntax

| Unit | Meaning | Example |
| --- | --- | --- |
| `s` | seconds | `90s` |
| `m` | minutes | `30m` |
| `h` | hours | `2h` |
| `d` | days | `1d` |

Components combine in descending order — `1h30m`, `1d2h` — and a bare integer is
read as seconds, for `caffeinate`-style muscle memory.

Two forms are rejected rather than guessed at:

- A trailing number with no unit (`1h30`) is ambiguous, and is an error instead
  of silently meaning `1h30m` or `1h30s`.
- A zero or negative duration (`0`, `0m`) is an error — an assertion that expires
  immediately is never what you meant.

Invalid input fails before any assertion is acquired, so a typo can never leave
your Mac awake:

```console
$ guaranate 1h30
Error: Invalid duration: '1h30'. Use forms like 30m, 2h, 1h30m, 90s, or a plain number of seconds.
```

## Indefinite sessions

Omit the duration to stay awake until you stop it:

```bash
guaranate
```

The live frame swaps the progress bar for a spinner (`⠋ Awake — until
interrupted`). Press `q` or Ctrl+C to end it.

## Ending a session

<img src="/brand/happy.png" alt="" aria-hidden="true" width="120" align="right" />

| How it ends | Exit code |
| --- | --- |
| The duration elapses | `0` |
| `q` on a TTY | `130` |
| Ctrl+C (`SIGINT`) | `130` |
| `SIGTERM` (e.g. `kill`) | `130` |

Every one of those paths releases the assertion first. Nothing is left behind
for you to clean up, which is the guarantee the project's end-to-end smoke test
exists to defend.

## Assertion modes

The default prevents **user-idle system sleep** while still letting the display
sleep — the right mode for builds, downloads, and unattended compute.

```bash
guaranate 2h              # prevent idle system sleep (display may sleep)
guaranate 2h --display    # also keep the display awake
guaranate 2h --system     # prevent all system sleep
```

| Flag | IOKit assertion | Display |
| --- | --- | --- |
| *(default)* | `PreventUserIdleSystemSleep` | may sleep |
| `-d`, `--display` | `PreventUserIdleDisplaySleep` | kept awake |
| `-s`, `--system` | `PreventSystemSleep` | may sleep |

`--display` and `--system` are mutually exclusive; asking for both is a
validation error rather than a silent precedence rule.

## Labelling a session

`--reason` sets the text macOS records on the assertion, which is what you (or a
teammate) will see in `pmset -g assertions`:

```bash
guaranate 3h --reason "nightly dataset export"
```

The default is `Guaranate timed session`. Give long sessions a real reason — it
is the only thing that explains *why* a machine is awake an hour later.

## The live frame

On a color terminal, a running session renders a gradient progress bar, a
metrics table, and a centered header, sized to the terminal width:

```text
             🌿 Guaranate

  ▏██████████████░░░░░░░░░░░░░░▕   50%

  Elapsed       · · · · · · · 00:42:17
  Remaining     · · · · · · · 01:17:43
  Ends          · · · · · · · 23:43:07
  Assertion     · · · · · System sleep
  Display       · · · · · ·  May sleep

Press Ctrl+C or q to stop
```

The cursor is hidden while the frame is live and restored on exit, and a summary
card is printed when the session completes.

### Terminals that can't do that

Color and Unicode degrade independently, so the frame stays readable everywhere:

- `NO_COLOR` drops color but keeps the Unicode bar.
- A non-UTF-8 locale falls back to a plain ASCII bar (`[####----]`) and keeps
  color; `TERM=dumb` (or no `TERM`) drops color as well.

Cursor hiding and frame redraws are the one thing tied to the terminal rather
than to color: those escape sequences are written whenever stdout is a TTY.

### Scripts, pipes, and CI

When stdout is not a TTY, the frame collapses to one start line and a two-line
completion summary — no per-second redraw churn in your log file:

```bash
guaranate 2h --reason "release build" >> keepawake.log 2>&1 &
```

Keyboard controls are inactive without a TTY; signals still work, so `kill` on
the process ends the session cleanly.

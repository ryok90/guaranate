---
title: Tying a session to a process
description: Holding the assertion for exactly one command's lifetime with guaranate while, watching an already-running pid, exit codes, and signal behaviour.
---

A timed session asks you to guess how long the work will take. Two forms remove
the guess by tying the session to a process instead: `guaranate while <command>`
runs the work itself, and `guaranate --watch <pid>` attaches to work that is
already running. Both hold the assertion for exactly that process's lifetime and
release it the moment it ends.

## Wrapping a command

`guaranate while` acquires the assertion, launches the command, holds the
assertion for as long as the command runs, releases it, and exits with the
command's own exit code:

```bash
guaranate while npm test
guaranate while ./build.sh --release
guaranate while cargo build --release
```

There is nothing to guess and nothing to clean up: the session cannot outlive the
work, and it cannot end early either.

### The command owns the terminal

The command's stdout, stderr, and stdin pass straight through — it is talking to
your terminal, not to Guaranate. That is also why there is no live frame here:
redrawing over the command's own output would corrupt it. You get one start line
and a two-line completion summary around whatever the command prints:

```console
$ guaranate while sh -c 'echo building; sleep 1'
🌿 Guaranate — staying awake while sh -c "echo building; sleep 1" runs · System sleep, display may sleep
building
✓ sh -c "echo building; sleep 1" finished after 1s
✓ Sleep-prevention assertion released
```

### Exit codes

Guaranate is transparent to `$?`, including the shell's own conventions for the
ways a command can fail to run:

| How the command ended | Exit code |
| --- | --- |
| It exited on its own | its own exit code |
| Killed by a signal | `128 + signal` — `130` for `SIGINT`, `143` for `SIGTERM` |
| Command not found | `127` |
| Found, but not executable | `126` |

```console
$ guaranate while sh -c 'exit 7'
🌿 Guaranate — staying awake while sh -c "exit 7" runs · System sleep, display may sleep
✗ sh -c "exit 7" exited 7 after 0s
✓ Sleep-prevention assertion released
$ echo $?
7
```

That makes `guaranate while` safe to drop in front of a command in a script or a
CI step without changing what the step reports.

### Signals

`SIGINT` (Ctrl+C), `SIGTERM`, and `SIGHUP` are forwarded to the command, and
Guaranate then waits for it to exit before releasing the assertion. Both halves
of that matter:

- The command is never orphaned — Guaranate does not exit out from under work it
  started.
- No exit path leaves a stale assertion behind, so your Mac is never left awake
  by a session whose command is already gone.

### Where the flags go

Guaranate's own flags belong *before* the command. Everything from the first
non-flag token onwards is handed to the command untouched:

```bash
guaranate while --display npm test    # --display is Guaranate's
guaranate while ./build.sh --release  # --release is the script's
```

`--` is optional, and stripped when present. Reach for it when the command's own
first argument could be mistaken for one of Guaranate's:

```bash
guaranate while --display -- ./build.sh --release
```

`while` takes `-d`/`--display`, `-s`/`--system`, and `-r`/`--reason <text>`, which
mean exactly what they mean for a timed session, and `guaranate while --help`
prints Guaranate's help rather than being handed to a command.

Without `--reason`, the assertion is labelled `while: <the command>` (truncated
for very long commands), so `pmset -g assertions` names the work rather than the
tool.

## Watching a process that already runs

When the work is already running, give Guaranate its pid with `-w`/`--watch` and
the session lasts until that process exits:

```bash
guaranate --watch 4821
guaranate -w "$(pgrep -n ffmpeg)"
```

### It only observes

Guaranate never starts, signals, or kills a watched process. Ctrl+C ends *your*
session — the assertion is released, Guaranate exits `130`, and the watched
process keeps running, unaware it was being watched. A process belonging to
another user can be watched too.

The session is bound to the process's pid *and* start time, not to the number
alone. If the watched process exits and macOS recycles its pid, the session ends;
an unrelated new process can never silently inherit the assertion.

### What it looks like

The live frame swaps the progress bar for a spinner and adds a `Watching` row
naming the process:

```text
             🌿 Guaranate

  ⠋ Awake — until the watched process exits

  Elapsed       · · · · · · · 00:03:12
  Watching      · · · ·  4821 (ffmpeg)
  Assertion     · · · · · System sleep
  Display       · · · · · ·  May sleep

Press Ctrl+C or q to stop
```

The assertion is attributed to the watched process, not just to Guaranate, so
`pmset` points at the real work — and its default reason names it too:

```console
$ pmset -g assertions | grep -A1 Watching
   pid 76280(guaranate): [0x0007c50900019ecf] PreventUserIdleSystemSleep named: "Watching 4821 (ffmpeg)"
	Created for PID: 4821.
```

### Pids that cannot be watched

A pid that is not in use is rejected before anything is acquired, so a typo
cannot leave your Mac awake:

```console
$ guaranate --watch 999999
Error: No process with pid 999999.
```

That exits `64`. Pid `0`, a negative pid, and Guaranate's own pid are rejected
the same way.

A session is either timed or tied to a process, never both:

```console
$ guaranate 10m --watch 5
Error: Choose either a duration or --watch <pid>, not both.
```

## Which form to reach for

| What you have | Reach for |
| --- | --- |
| A command you are about to run | `guaranate while <command>` |
| A process that is already running | `guaranate --watch <pid>` |
| A deadline rather than a process | [`guaranate <duration>`](/guides/timed-sessions/) |

Prefer `while` whenever you can put Guaranate in front of the work: it needs no
pid, it ends at exactly the right moment, and its exit code is the work's. Reach
for `--watch` when the work started without you — a long build in another
terminal, a colleague's export, a process you would rather not restart just to
wrap it.

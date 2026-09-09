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
🌿 Guaranate — staying awake while sh -c "echo building; sleep 1" runs · System sleep prevented, display may sleep
building
✓ sh -c "echo building; sleep 1" finished after 1s
✓ Sleep-prevention assertion released
```

Those two bookends are Guaranate's, so they go to **stderr**. Stdout carries the
command's own bytes and nothing else, which is what makes `while` safe in a
pipeline or a redirect:

```console
$ guaranate while curl -s https://example.com/data.json > data.json
🌿 Guaranate — staying awake while curl -s https://example.com/data.json runs · System sleep prevented, display may sleep
✓ curl -s https://example.com/data.json finished after 2s
✓ Sleep-prevention assertion released
$ head -c 1 data.json    # the file holds the command's output, not Guaranate's
{
```

In a pipeline the command reaches the reader directly, so a reader that goes away
is the command's business, not the session's. `guaranate while yes | head -1` ends
the way `yes | head -1` does: `head` closes the pipe, `yes` dies of `SIGPIPE`, and
Guaranate reports it and propagates `141`.

```console
$ guaranate while yes | head -1
🌿 Guaranate — staying awake while yes runs · System sleep prevented, display may sleep
y
✗ yes killed by SIGPIPE after 0s
✓ Sleep-prevention assertion released
```

"The way `yes | head -1` does" is the whole promise, including when that differs:
run from a shell that ignores `SIGPIPE` — some CI runners do — the command gets
`EPIPE` from the failed write and exits `1` instead. Wrapped or not, the outcome is
the same, because Guaranate leaves the caller's dispositions alone.

What a broken or closed stream can never do is end the session itself. Guaranate's
own writes tolerate failure, so `guaranate while make > /dev/full` or a status line
nobody is reading costs you the line — never the build, and never the assertion.

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
🌿 Guaranate — staying awake while sh -c "exit 7" runs · System sleep prevented, display may sleep
✗ sh -c "exit 7" exited 7 after 0s
✓ Sleep-prevention assertion released
$ echo $?
7
```

That makes `guaranate while` safe to drop in front of a command in a script or a
CI step without changing what the step reports.

### Signals

The command runs in a process group of its own and is handed the controlling
terminal, so Ctrl+C, Ctrl+Z, and stdin behave exactly as they would if you had
run the command without Guaranate in front. A terminal interrupt reaches the
command once — delivered by the kernel to its whole group — and never twice,
which would make tools that treat a second interrupt as "force quit now"
(`docker compose`, many dev servers) do exactly that on your first keypress.

Signals sent to *Guaranate itself* — a CI cancel, a `kill -TERM` against its
pid — are relayed to the command's whole process group, so the command's own
children are signalled with it rather than left running behind a released
assertion. What each process does with the signal is still its own business: a
descendant that ignores or outlives `SIGTERM` keeps running, exactly as it would
if you had started the command yourself.

Either way, Guaranate waits for the command to actually exit before releasing
the assertion. Both halves of that matter:

- The command is never orphaned — Guaranate does not exit out from under work it
  started.
- No exit path leaves a stale assertion behind, so your Mac is never left awake
  by a session whose command is already gone.

### Pausing and resuming

Ctrl+Z stops the whole job — the command, and Guaranate with it — so your shell
reports it as stopped and `fg` resumes both halves together. The assertion is
deliberately kept while the command is paused: a pause is not an ending, and the
work is still there to come back to.

A pause is not a hiding place either, but the way out is a continue rather than a
kill. A stopped process runs no code, so a signal that arrives while the job is
paused is relayed the moment it is resumed — and everything that could otherwise
strand a paused job resumes it for you: `fg`, `bg`, and `kill %job` all send
`SIGCONT` along, and when a terminal closes, the kernel is required to send
`SIGHUP` **and** `SIGCONT` to a job left stopped behind it. So a `kill` against a
paused session takes effect, the command is signalled rather than abandoned, and
the assertion is released once it has actually gone. A bare `kill -STOP` you sent
yourself is the one exception: you are holding the pause, so continue it (or
`kill -9`, which always works — the kernel drops assertions with the process).

### Your signal choices survive

Signal dispositions are inherited, and Guaranate keeps it that way. A shell
running a background job makes it immune to Ctrl+C by ignoring `SIGINT` in it; a
script may deliberately ignore `SIGTERM` before starting work. Wrapping such a
command in `guaranate while` does not change that: only the dispositions Guaranate
took over for itself are restored in the command, so the work reacts to signals
exactly as it would unwrapped.

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

A token that looks like one of Guaranate's flags is never run as a program. A
mistyped flag before the command is reported instead:

```console
$ guaranate while -w 1234
Error: Unknown option '-w'. Guaranate's own flags go before the command; to run a program whose name starts with '-', put `--` first.
```

That exits `64`. `--` is how you run a program whose own name really does start
with `-`: `guaranate while -- -w 1234` runs a program named `-w`.

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
the same way — and so is a process that has already exited but whose parent has
not collected it yet: it still answers to its pid, but there is nothing left to
wait for.

The reverse case is treated as an error too. If the process exists but the kernel
will not report its exit — a descriptor limit, or anything else that makes the
watch impossible — Guaranate says so, releases, and exits `71` rather than exiting
`0` as though the work had finished. A watch that cannot be established is not a
watch that succeeded.

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

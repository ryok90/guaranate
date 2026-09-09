#!/usr/bin/env python3
"""Simulates a job-control shell around `guaranate while`, and reports who owns
the terminal after the job is resumed.

A non-interactive shell cannot stand in for this: it blocks forever on a stopped
foreground job, so there is no way to reach `fg`/`bg` from a plain script. This
does what a shell does, in order, with no shell involved:

  1. Put the job in its own process group and give it the terminal (a foreground
     start — this is what makes the session own the terminal at all).
  2. Send SIGTSTP to the terminal's foreground process group, which by then is the
     command's own group. That is Ctrl+Z.
  3. Reclaim the terminal, as a shell does whenever a job stops.
  4. Resume the job: `fg` hands the terminal over first, `bg` keeps it.

Usage: job-control-probe.py <guaranate-binary> <reason> <fg|bg> [command...]
Prints `KEY=value` lines for the caller to assert on.
"""
import fcntl
import os
import signal
import subprocess
import sys
import termios
import time

BIN, REASON, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
COMMAND = sys.argv[4:] or ["/bin/sh", "-c", "sleep 10"]
JOB_CONTROL_SIGNALS = (signal.SIGTTOU, signal.SIGTTIN, signal.SIGTSTP, signal.SIGINT)


def pgid_of(pid):
    out = subprocess.run(["ps", "-o", "pgid=", "-p", str(pid)], capture_output=True, text=True)
    return out.stdout.strip() or "gone"


def state_of(pid):
    out = subprocess.run(["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True)
    return out.stdout.strip() or "gone"


master, slave = os.openpty()
shell = os.fork()
if shell == 0:
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.close(slave)
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    # A shell ignores these; that is what lets it reclaim the terminal from a
    # background process group without stopping itself.
    for sig in JOB_CONTROL_SIGNALS:
        signal.signal(sig, signal.SIG_IGN)
    shell_pgid = os.getpgrp()

    job = os.fork()
    if job == 0:
        os.setpgid(0, 0)
        # And it resets what it ignores before exec, so the job is not born deaf.
        for sig in JOB_CONTROL_SIGNALS:
            signal.signal(sig, signal.SIG_DFL)
        os.execv(BIN, [BIN, "while", "--reason", REASON] + COMMAND)
    os.setpgid(job, job)
    os.tcsetpgrp(0, job)
    time.sleep(1.5)

    command = subprocess.run(["pgrep", "-P", str(job)], capture_output=True, text=True).stdout.split()
    command_pid = int(command[0]) if command else 0

    os.kill(-os.tcgetpgrp(0), signal.SIGTSTP)  # Ctrl+Z
    time.sleep(1.0)
    stopped_session, stopped_command = state_of(job), state_of(command_pid)

    os.tcsetpgrp(0, shell_pgid)  # the shell takes its terminal back
    time.sleep(0.3)
    if MODE == "fg":
        os.tcsetpgrp(0, job)
    os.kill(-job, signal.SIGCONT)
    time.sleep(1.5)

    alive = "no"
    if command_pid:
        try:
            os.kill(command_pid, 0)
            alive = "yes"
        except OSError:
            pass

    report = (
        f"SHELL={shell_pgid}\n"
        f"SESSION={job}\n"
        f"COMMANDGROUP={pgid_of(command_pid)}\n"
        f"STOPPED_SESSION={stopped_session}\n"
        f"STOPPED_COMMAND={stopped_command}\n"
        f"FOREGROUND={os.tcgetpgrp(0)}\n"
        f"ALIVE={alive}\n"
    )
    os.write(2, report.encode())
    if command_pid:
        os.kill(-command_pid, signal.SIGCONT)
        os.kill(-command_pid, signal.SIGKILL)
    os.kill(job, signal.SIGCONT)
    os.kill(job, signal.SIGKILL)
    os._exit(0)

os.close(slave)
collected = b""
deadline = time.time() + 20
while time.time() < deadline:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    collected += chunk
os.waitpid(shell, 0)
sys.stdout.write(collected.decode(errors="replace").replace("\r", ""))

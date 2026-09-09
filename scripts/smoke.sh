#!/usr/bin/env bash
#
# End-to-end smoke test for the guaranate binary.
#
# Drives the real CLI against the native IOKit power-assertion API and verifies
# the non-negotiable: no exit path may leave a stale assertion, and no released
# assertion may leave work still running. Covers timed expiry (exit 0), SIGINT
# (exit 130), `while` (command lifetime, exit-status propagation, process-group
# signal delivery, terminal handoff, job control, orphan-free teardown), and
# `--watch` (releases on the watched process's exit, detaches without killing
# it). This lives here (not in `swift test`) because it mutates the host's real
# sleep state via IOKit, which XCTest must never do (see AGENTS.md "Testing
# conventions").
#
# Usage: scripts/smoke.sh [path-to-guaranate]
#   Defaults to .build/release/guaranate, building it if missing.
#   Override with $GUARANATE_BIN or the first argument.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

BIN="${1:-${GUARANATE_BIN:-.build/release/guaranate}}"

if [[ ! -x "$BIN" ]]; then
  echo "· binary not found at $BIN — building release…"
  swift build -c release
fi

echo "· using binary: $BIN"
echo "· $("$BIN" --version)"

# Unique per-run reason so pmset greps can't collide with other assertions.
tag="smoke-$$-$(date +%s)"
child_pid=""
target_pid=""
extra_pid=""

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

# Kill any lingering child on unexpected exit so we never leak an assertion.
cleanup() {
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
    kill -KILL "$target_pid" 2>/dev/null || true
  fi
  if [[ -n "$extra_pid" ]] && kill -0 "$extra_pid" 2>/dev/null; then
    kill -KILL "$extra_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

assertion_present() {
  # Capture then substring-match: piping into `grep -q` would let grep exit on
  # first match, kill `pmset` with SIGPIPE, and trip `set -o pipefail` even on a
  # successful match.
  local out
  out="$(pmset -g assertions)"
  [[ "$out" == *"$1"* ]]
}

# Poll until the assertion tagged $1 is present ($2=present) or absent
# ($2=absent), failing after ~5s so a hang surfaces as a test failure.
wait_for_assertion() {
  local reason="$1" want="$2" i=0
  while (( i < 50 )); do
    if [[ "$want" == "present" ]]; then
      assertion_present "$reason" && return 0
    else
      assertion_present "$reason" || return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  return 1
}

# --- Test 1: timed expiry releases the assertion and exits 0 ------------------
echo
echo "▸ Test 1: timed expiry (exit 0, clean release)"
reason1="$tag-expiry"
"$BIN" 3 --reason "$reason1" >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason1" present || fail "assertion '$reason1' never appeared in pmset while held"
echo "  ✓ assertion live in pmset while running"

status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 0 )) || fail "expected exit 0 on expiry, got $status"
echo "  ✓ exited 0 on expiry"

wait_for_assertion "$reason1" absent || fail "stale assertion '$reason1' left behind after exit"
echo "  ✓ no stale assertion after exit"

# --- Test 2: SIGINT releases the assertion and exits 130 ----------------------
echo
echo "▸ Test 2: SIGINT (exit 130, clean release)"
reason2="$tag-sigint"
"$BIN" 30 --reason "$reason2" >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason2" present || fail "assertion '$reason2' never appeared in pmset while held"
echo "  ✓ assertion live in pmset while running"

kill -INT "$child_pid"
status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 130 )) || fail "expected exit 130 on SIGINT, got $status"
echo "  ✓ exited 130 on SIGINT"

wait_for_assertion "$reason2" absent || fail "stale assertion '$reason2' left behind after SIGINT"
echo "  ✓ no stale assertion after SIGINT"

# --- Test 3: `while` holds for exactly the command's lifetime ------------------
echo
echo "▸ Test 3: while (command lifetime, exit 0, clean release, no orphan)"
reason3="$tag-while"
"$BIN" while --reason "$reason3" /bin/sleep 3 >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason3" present || fail "assertion '$reason3' never appeared in pmset while the command ran"
echo "  ✓ assertion live in pmset while the command runs"

command_pid="$(pgrep -P "$child_pid" || true)"
[[ -n "$command_pid" ]] || fail "could not find the pid of the spawned command"

status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 0 )) || fail "expected exit 0 for a successful command, got $status"
echo "  ✓ exited 0 when the command succeeded"

wait_for_assertion "$reason3" absent || fail "stale assertion '$reason3' left behind after the command exited"
echo "  ✓ no stale assertion after the command exited"

if kill -0 "$command_pid" 2>/dev/null; then fail "command pid $command_pid outlived the session"; fi
echo "  ✓ command was not orphaned"

# --- Test 4: `while` propagates the command's exit status ----------------------
echo
echo "▸ Test 4: while (exit-status propagation)"
reason4="$tag-status"
status=0
"$BIN" while --reason "$reason4" /bin/sh -c 'exit 7' >/dev/null 2>&1 || status=$?
(( status == 7 )) || fail "expected exit 7 from 'exit 7', got $status"
echo "  ✓ non-zero exit code propagated (7)"

status=0
"$BIN" while --reason "$reason4" /bin/sh -c 'kill -TERM $$' >/dev/null 2>&1 || status=$?
(( status == 143 )) || fail "expected exit 143 (128+SIGTERM) from a signalled command, got $status"
echo "  ✓ signal death propagated as 128+signal (143)"

status=0
"$BIN" while --reason "$reason4" guaranate-no-such-command >/dev/null 2>&1 || status=$?
(( status == 127 )) || fail "expected exit 127 for a missing command, got $status"
echo "  ✓ missing command exits 127"

wait_for_assertion "$reason4" absent || fail "stale assertion '$reason4' left behind"
echo "  ✓ no stale assertion after any of them"

# --- Test 5: SIGINT reaches the command and releases the assertion -------------
echo
echo "▸ Test 5: while + SIGINT (command interrupted, exit 130, clean release)"
reason5="$tag-while-sigint"
# Job control is deliberate: a shell without it makes background children immune
# to SIGINT by ignoring it in them, and Guaranate now preserves that inherited
# disposition rather than overriding the caller (test 22). This is therefore the
# interactive context — the one where an interrupt is supposed to reach the work.
set -m
"$BIN" while --reason "$reason5" /bin/sleep 30 >/dev/null 2>&1 &
child_pid=$!
set +m

wait_for_assertion "$reason5" present || fail "assertion '$reason5' never appeared in pmset"
command_pid="$(pgrep -P "$child_pid" || true)"
[[ -n "$command_pid" ]] || fail "could not find the pid of the spawned command"

kill -INT "$child_pid"
status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 130 )) || fail "expected exit 130 (128+SIGINT) after SIGINT, got $status"
echo "  ✓ exited 130 after SIGINT"

if kill -0 "$command_pid" 2>/dev/null; then fail "command pid $command_pid survived SIGINT"; fi
echo "  ✓ SIGINT reached the command"

wait_for_assertion "$reason5" absent || fail "stale assertion '$reason5' left behind after SIGINT"
echo "  ✓ no stale assertion after SIGINT"

# --- Test 6: `--watch` releases when the watched process exits -----------------
echo
echo "▸ Test 6: --watch (releases when the watched process exits)"
reason6="$tag-watch"
/bin/sleep 3 &
target_pid=$!
"$BIN" --watch "$target_pid" --reason "$reason6" >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason6" present || fail "assertion '$reason6' never appeared in pmset while watching"
echo "  ✓ assertion live in pmset while the watched process runs"

status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 0 )) || fail "expected exit 0 when the watched process exits, got $status"
echo "  ✓ exited 0 when the watched process exited"

wait "$target_pid" 2>/dev/null || true
target_pid=""
wait_for_assertion "$reason6" absent || fail "stale assertion '$reason6' left behind"
echo "  ✓ no stale assertion after the watched process exited"

# --- Test 7: SIGINT detaches from the watched process without killing it -------
echo
echo "▸ Test 7: --watch + SIGINT (detaches, leaves the watched process alone)"
reason7="$tag-watch-sigint"
/bin/sleep 30 &
target_pid=$!
"$BIN" --watch "$target_pid" --reason "$reason7" >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason7" present || fail "assertion '$reason7' never appeared in pmset while watching"

kill -INT "$child_pid"
status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 130 )) || fail "expected exit 130 on SIGINT, got $status"
echo "  ✓ exited 130 on SIGINT"

kill -0 "$target_pid" 2>/dev/null || fail "watched process $target_pid was killed; watching must never signal it"
echo "  ✓ watched process left running"

wait_for_assertion "$reason7" absent || fail "stale assertion '$reason7' left behind after SIGINT"
echo "  ✓ no stale assertion after SIGINT"

kill -TERM "$target_pid" 2>/dev/null || true
wait "$target_pid" 2>/dev/null || true
target_pid=""

# --- Test 8: an unused pid is rejected without acquiring anything --------------
echo
echo "▸ Test 8: --watch with an unused pid (rejected, nothing acquired)"
reason8="$tag-watch-missing"
status=0
"$BIN" --watch 999999 --reason "$reason8" >/dev/null 2>&1 || status=$?
(( status == 64 )) || fail "expected exit 64 for an unused pid, got $status"
if assertion_present "$reason8"; then fail "an assertion was acquired for a nonexistent pid"; fi
echo "  ✓ rejected an unused pid without acquiring an assertion"

# --- Test 9: a forwarded signal tears down the command's own children ----------
echo
echo "▸ Test 9: while (a forwarded signal reaches the command's children)"
reason9="$tag-while-group"
"$BIN" while --reason "$reason9" /bin/sh -c '/bin/sleep 45 & wait' >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason9" present || fail "assertion '$reason9' never appeared in pmset"
command_pid="$(pgrep -P "$child_pid" || true)"
[[ -n "$command_pid" ]] || fail "could not find the pid of the spawned command"
extra_pid="$(pgrep -P "$command_pid" || true)"
[[ -n "$extra_pid" ]] || fail "the command never spawned a child of its own"

# The command leads a group of its own: a terminal signal then reaches it and its
# children as one unit and never reaches guaranate, which is what keeps a single
# Ctrl+C from being delivered to the command twice.
command_pgid="$(ps -o pgid= -p "$command_pid" | tr -d ' ')"
session_pgid="$(ps -o pgid= -p "$child_pid" | tr -d ' ')"
[[ "$command_pgid" == "$command_pid" ]] || fail "command $command_pid is not its own process-group leader (pgid $command_pgid)"
[[ "$command_pgid" != "$session_pgid" ]] || fail "the command shares guaranate's process group ($command_pgid)"
echo "  ✓ the command runs in a process group of its own"

kill -TERM "$child_pid"
status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 143 )) || fail "expected exit 143 (128+SIGTERM), got $status"

if kill -0 "$extra_pid" 2>/dev/null; then
  fail "the command's child $extra_pid outlived the released assertion"
fi
extra_pid=""
echo "  ✓ the command's children were torn down with it"

wait_for_assertion "$reason9" absent || fail "stale assertion '$reason9' left behind"
echo "  ✓ no stale assertion, and no work left running behind a released one"

# --- Test 10: under a terminal, the command becomes the foreground group -------
echo
echo "▸ Test 10: while (the command is handed the controlling terminal)"
reason10="$tag-while-tty"
# `script` supplies a real pty: without one there is no foreground process group
# to hand over, so there is nothing to assert.
script -q /dev/null "$BIN" while --reason "$reason10" /bin/sleep 5 >/dev/null 2>&1 &
extra_pid=$!

wait_for_assertion "$reason10" present || fail "assertion '$reason10' never appeared in pmset"
session_pid="$(pgrep -P "$extra_pid" | head -1 || true)"
[[ -n "$session_pid" ]] || fail "could not find guaranate under script(1)"
command_pid="$(pgrep -P "$session_pid" | head -1 || true)"
[[ -n "$command_pid" ]] || fail "could not find the command under guaranate"

foreground_pgid="$(ps -o tpgid= -p "$session_pid" | tr -d ' ')"
command_pgid="$(ps -o pgid= -p "$command_pid" | tr -d ' ')"
[[ "$foreground_pgid" == "$command_pgid" ]] \
  || fail "terminal foreground group is $foreground_pgid, expected the command's $command_pgid"
echo "  ✓ the command owns the terminal, so a keypress is delivered to it once"

wait "$extra_pid" 2>/dev/null || true
extra_pid=""
wait_for_assertion "$reason10" absent || fail "stale assertion '$reason10' left behind"
echo "  ✓ terminal handed back and assertion released"

# --- Test 11: Ctrl+Z stops the whole job and keeps the assertion ---------------
echo
echo "▸ Test 11: while + SIGTSTP (job control; a pause is not an ending)"
reason11="$tag-while-stop"
"$BIN" while --reason "$reason11" /bin/sh -c '/bin/sleep 2; exit 5' >/dev/null 2>&1 &
child_pid=$!

wait_for_assertion "$reason11" present || fail "assertion '$reason11' never appeared in pmset"
command_pid="$(pgrep -P "$child_pid" | head -1 || true)"
[[ -n "$command_pid" ]] || fail "could not find the pid of the spawned command"

state_of() { ps -o state= -p "$1" 2>/dev/null | cut -c1; }

# Exactly what a terminal does for Ctrl+Z: stop the foreground process group.
kill -TSTP "-$command_pid"
for _ in $(seq 1 50); do
  [[ "$(state_of "$child_pid")" == "T" ]] && break
  sleep 0.1
done
[[ "$(state_of "$child_pid")" == "T" ]] || fail "guaranate kept running while the command was stopped"
[[ "$(state_of "$command_pid")" == "T" ]] || fail "the command did not stop"
assertion_present "$reason11" || fail "assertion released while the command was only paused"
echo "  ✓ both halves stopped, assertion still held"

kill -CONT "$child_pid"   # what `fg` sends
status=0
wait "$child_pid" || status=$?
child_pid=""
(( status == 5 )) || fail "expected the command's own exit 5 after resuming, got $status"
echo "  ✓ resumed to completion and propagated the command's exit code"

wait_for_assertion "$reason11" absent || fail "stale assertion '$reason11' left behind"
echo "  ✓ no stale assertion"

# --- Test 12: stdout belongs to the command alone ------------------------------
echo
echo "▸ Test 12: while (stdout carries only the command's bytes)"
reason12="$tag-while-stdout"
out_file="$(mktemp)"
"$BIN" while --reason "$reason12" /bin/sh -c 'printf "{\"ok\":true}\n"' >"$out_file" 2>/dev/null
[[ "$(cat "$out_file")" == '{"ok":true}' ]] \
  || fail "redirected stdout was polluted: $(cat "$out_file")"
rm -f "$out_file"
echo "  ✓ redirected stdout is byte-for-byte the command's own output"

# Guaranate's own bookends are diagnostics, so they go to stderr.
err_file="$(mktemp)"
"$BIN" while --reason "$reason12" /bin/sh -c 'true' >/dev/null 2>"$err_file"
grep -q "Guaranate" "$err_file" || fail "the start line did not reach stderr"
rm -f "$err_file"
echo "  ✓ the session's own lines go to stderr"

# --- Test 13: output failures must not end a session ---------------------------
echo
echo "▸ Test 13: a closed or unread output stream cannot end a session"
reason13="$tag-while-epipe"
marker="$(mktemp)"
# `true` exits before guaranate writes anything, so an unguarded write would take
# SIGPIPE and tear the session down before the command had even run. `set +e`
# because the command's non-zero exit is the point of the test, and `pipefail`
# would otherwise end the script here.
set +e
"$BIN" while --reason "$reason13" /bin/sh -c "sleep 0.4; echo ran > $marker; exit 7" 2>/dev/null | true
status="${PIPESTATUS[0]}"
set -e
(( status == 7 )) || fail "expected the command's exit 7 with a closed stdout reader, got $status"
[[ "$(cat "$marker")" == "ran" ]] || fail "the command never ran when stdout had no reader"
rm -f "$marker"
echo "  ✓ the command ran to completion and its exit code survived"

wait_for_assertion "$reason13" absent || fail "stale assertion '$reason13' left behind"
echo "  ✓ no stale assertion"

# Both streams gone entirely, not just unread.
marker="$(mktemp)"
rm -f "$marker"
status=0
"$BIN" while --reason "$reason13" /bin/sh -c "echo ran > $marker; exit 5" >&- 2>&- || status=$?
(( status == 5 )) || fail "expected the command's exit 5 with stdout and stderr closed, got $status"
[[ "$(cat "$marker" 2>/dev/null)" == "ran" ]] || fail "the command never ran with its output streams closed"
rm -f "$marker"
echo "  ✓ closed stdout and stderr change nothing about the command or its code"

# The same hazard applies to a timed session, which writes a frame every second.
reason13b="$tag-timed-epipe"
set +e
"$BIN" 2 --reason "$reason13b" 2>/dev/null | true
status="${PIPESTATUS[0]}"
set -e
(( status == 0 )) || fail "a timed session died on a vanished stdout reader (exit $status)"
wait_for_assertion "$reason13b" absent || fail "stale assertion '$reason13b' left behind"
echo "  ✓ a timed session runs its full duration with no one reading stdout"

# --- Test 14: a zombie pid is rejected without acquiring anything --------------
echo
echo "▸ Test 14: --watch with a zombie pid (already exited, nothing acquired)"
reason14="$tag-watch-zombie"
# Making a zombie needs a parent that forks and then does not wait: `bash` reaps
# its background children on its own, so perl does the honours. Skipped rather
# than failed if perl ever stops shipping with macOS — the deterministic version
# of this check lives in `SystemProcessInspectorTests.testRejectsAZombie`.
if [[ -x /usr/bin/perl ]]; then
  zombie_file="$(mktemp)"
  /usr/bin/perl -e 'my $p = fork; exit 0 if $p == 0; open(F, ">", $ARGV[0]); print F "$p"; close F; sleep 6' \
    "$zombie_file" &
  extra_pid=$!
  sleep 0.6
  zombie_pid="$(cat "$zombie_file")"
  rm -f "$zombie_file"

  [[ -n "$zombie_pid" ]] || fail "could not create a zombie process"
  # The zombie signature: it still exists for kill(2), while `ps` reports it as
  # `<defunct>` (or not at all) rather than as a live process.
  kill -0 "$zombie_pid" 2>/dev/null || fail "pid $zombie_pid is not a zombie: it no longer exists"
  zombie_comm="$(ps -p "$zombie_pid" -o comm= 2>/dev/null || true)"
  [[ -z "$zombie_comm" || "$zombie_comm" == *defunct* ]] \
    || fail "pid $zombie_pid is a live process ($zombie_comm), not a zombie"

  status=0
  "$BIN" --watch "$zombie_pid" --reason "$reason14" >/dev/null 2>&1 || status=$?
  (( status == 64 )) || fail "expected exit 64 for a zombie pid, got $status"
  if assertion_present "$reason14"; then fail "an assertion was acquired for a zombie pid"; fi
  echo "  ✓ rejected an already-exited pid without acquiring an assertion"

  kill -TERM "$extra_pid" 2>/dev/null || true
  wait "$extra_pid" 2>/dev/null || true
  extra_pid=""
else
  echo "  · skipped: /usr/bin/perl is unavailable to create a zombie"
fi

# --- Test 15: terminating a stopped session, without orphaning the command ------
echo
echo "▸ Test 15: while + SIGTERM while the job is stopped (relayed, never orphaned)"
reason15="$tag-while-stopped-term"
# The command ignores SIGHUP, so nothing but Guaranate's own relay can end it:
# that is what makes this a no-orphan test and not a kernel-cleanup test.
"$BIN" while --reason "$reason15" /bin/sh -c "trap '' HUP; sleep 30" 2>/dev/null &
child_pid=$!
wait_for_assertion "$reason15" present || fail "assertion never appeared"
command_pid="$(pgrep -P "$child_pid" | head -1)"
[[ -n "$command_pid" ]] || fail "could not find the command's pid"
# Stop the command's group, exactly as Ctrl+Z does, and let Guaranate mirror it.
kill -TSTP "-$command_pid" 2>/dev/null || fail "could not stop the command's group"
for _ in $(seq 1 30); do
  [[ "$(ps -o state= -p "$child_pid" | tr -d ' ')" == T* ]] && break
  sleep 0.1
done
[[ "$(ps -o state= -p "$child_pid" | tr -d ' ')" == T* ]] || fail "Guaranate did not mirror the stop"
assertion_present "$reason15" || fail "the assertion was dropped while the command was paused"
echo "  ✓ the assertion is held while both halves are stopped"

# A stopped process runs no code, so the signal waits for the continue that every
# real path supplies — `fg`, `bg`, POSIX `kill %job`, or the kernel itself when the
# group is orphaned. What must never happen is the session dying without relaying,
# which would leave this SIGHUP-proof command running behind a released assertion.
kill -TERM "$child_pid"
sleep 0.5
[[ "$(ps -o state= -p "$child_pid" | tr -d ' ')" == T* ]] \
  || fail "the session acted on a signal while it was stopped, without relaying"
assertion_present "$reason15" || fail "the assertion was released while the command still ran"
kill -CONT "$child_pid"                 # what `kill %job` and `fg` do for you
status=0
wait "$child_pid" 2>/dev/null || status=$?
(( status == 143 )) || fail "expected 143 after the relayed SIGTERM, got $status"
for _ in $(seq 1 50); do kill -0 "$command_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$command_pid" 2>/dev/null && fail "the command outlived the terminated session"
child_pid=""
wait_for_assertion "$reason15" absent || fail "stale assertion '$reason15' left behind"
echo "  ✓ once continued, the signal is relayed and a SIGHUP-proof command still dies"
echo "  ✓ exit 143, no orphan, no stale assertion"

# --- Test 16: a command killed while it is still suspended ---------------------
echo
echo "▸ Test 16: while (a command killed before it is resumed reports its real status)"
reason16="$tag-while-suspended"
# The startup window is made deterministic by blocking the start-line write: a
# line larger than the pipe buffer cannot complete until the pipe is drained, and
# the command stays suspended until it does.
big="$(printf 'x%.0s' $(seq 1 70000))"
pipe="$(mktemp -u)"
mkfifo "$pipe"
( exec 9<"$pipe"; sleep 5; cat <&9 >/dev/null ) &
extra_pid=$!
"$BIN" while --reason "$reason16" /bin/echo "$big" 2>"$pipe" &
child_pid=$!
sleep 1.5
command_pid="$(pgrep -P "$child_pid" | head -1)"
[[ -n "$command_pid" ]] || fail "could not find the suspended command"
[[ "$(ps -o state= -p "$command_pid" | tr -d ' ')" == T* ]] \
  || fail "the command was not suspended at startup"
kill -KILL "$command_pid"
status=0
wait "$child_pid" 2>/dev/null || status=$?
child_pid=""
(( status == 137 )) || fail "expected 137 for a command killed while suspended, got $status"
wait "$extra_pid" 2>/dev/null || true
extra_pid=""
rm -f "$pipe"
wait_for_assertion "$reason16" absent || fail "stale assertion '$reason16' left behind"
echo "  ✓ reported 128+SIGKILL rather than inventing an exit status"

# --- Test 17: closed stderr must not cost the launch-failure exit code ---------
echo
echo "▸ Test 17: while (a closed stderr still exits 127 for a missing command)"
status=0
"$BIN" while --reason "$tag-nostderr" definitely-not-a-real-command 2>&- || status=$?
(( status == 127 )) || fail "expected 127 with stderr closed, got $status"
echo "  ✓ the shell's conventional code survives an unwritable diagnostic"

# --- Test 18: a pipeline is the command's, not Guaranate's ---------------------
echo
echo "▸ Test 18: while (a pipe closing early reaches the command, not the session)"
reason18="$tag-while-pipe"
err_file="$(mktemp)"
# Measured against the unwrapped pipeline rather than a fixed code, because the
# right answer depends on the caller: with the default disposition the command dies
# of SIGPIPE (141), and under a caller that ignores SIGPIPE — CI runners commonly do
# — the write fails with EPIPE instead (1). Guaranate preserves whichever the
# command would have had, so the contract is "the same as without it in front".
set +e
yes 2>/dev/null | head -1 >/dev/null
baseline="${PIPESTATUS[0]}"
"$BIN" while --reason "$reason18" yes 2>"$err_file" | head -1 >/dev/null
status="${PIPESTATUS[0]}"
set -e
(( status == baseline )) \
  || fail "wrapped pipeline exited $status where the unwrapped one exited $baseline"
(( baseline != 0 )) || fail "the baseline pipeline did not report a broken pipe at all"
grep -q "staying awake" "$err_file" || fail "the start line was lost with the pipe"
grep -q "assertion released" "$err_file" || fail "the release line was lost with the pipe"
rm -f "$err_file"
wait_for_assertion "$reason18" absent || fail "stale assertion '$reason18' left behind"
echo "  ✓ the broken pipe reached the command exactly as unwrapped (exit $baseline)"
echo "  ✓ status output intact, no stale assertion"

# --- Test 19: a `tostop` terminal must not stop the session --------------------
echo
echo "▸ Test 19: while (on a terminal with tostop, the handover costs nothing)"
reason19="$tag-while-tostop"
# `set -m` gives Guaranate its own process group under a real pty, which is what
# makes a background write raise SIGTTOU rather than fail outright.
tostop_out="$(mktemp)"
script -q /dev/null /bin/bash --norc -c \
  "set -m; stty tostop; '$BIN' while --reason '$reason19' /bin/sh -c 'echo COMMAND_RAN'; echo \"RC=\$?\"" \
  >"$tostop_out" 2>&1 &
child_pid=$!
settled=0
for _ in $(seq 1 100); do
  grep -q "RC=" "$tostop_out" && { settled=1; break; }
  sleep 0.1
done
(( settled == 1 )) || fail "the session never finished on a tostop terminal (likely stopped by SIGTTOU)"
wait "$child_pid" 2>/dev/null || true
child_pid=""
grep -q "COMMAND_RAN" "$tostop_out" || fail "the command did not run on a tostop terminal"
grep -q "staying awake" "$tostop_out" || fail "the start line was lost on a tostop terminal"
grep -q "RC=0" "$tostop_out" || fail "the exit code did not survive a tostop terminal"
rm -f "$tostop_out"
wait_for_assertion "$reason19" absent || fail "stale assertion '$reason19' left behind"
echo "  ✓ start line, command output, and exit code all survive tostop"

# --- Test 20: a backgrounded timed session must keep running --------------------
echo
echo "▸ Test 20: timed session in the background (keeps holding, never stops itself)"
reason20="$tag-timed-background"
bg_out="$(mktemp)"
# `set -m` puts the session in its own process group under a real pty, so it is a
# background job of a job-control shell — the case where reaching for the keyboard
# would stop it on the first keystroke while it still held the assertion.
script -q /dev/null /bin/bash --norc -c \
  "set -m; '$BIN' 4 --reason '$reason20' & sleep 2; printf 'x\n'; sleep 1; \
   ps -o state= -p \$! | tr -d ' ' | sed 's/^/STATE=/'; wait \$!; echo \"RC=\$?\"" \
  >"$bg_out" 2>&1 &
child_pid=$!
settled=0
for _ in $(seq 1 150); do
  grep -q "RC=" "$bg_out" && { settled=1; break; }
  sleep 0.1
done
(( settled == 1 )) || fail "a backgrounded timed session never finished"
wait "$child_pid" 2>/dev/null || true
child_pid=""
grep -q "STATE=S" "$bg_out" || fail "a backgrounded timed session was stopped: $(grep STATE= "$bg_out")"
grep -q "RC=0" "$bg_out" || fail "a backgrounded timed session did not exit 0"
rm -f "$bg_out"
wait_for_assertion "$reason20" absent || fail "stale assertion '$reason20' left behind"
echo "  ✓ ran to its deadline in the background, keystrokes left to the shell"

# --- Test 21: a stopped job whose terminal disappears --------------------------
echo
echo "▸ Test 21: while (a stopped session is never stranded by a lost terminal)"
reason21="$tag-while-orphaned"
# A stopped process cannot act on anything, so a paused session would hold the
# assertion forever if nothing continued it. The kernel owes SIGHUP *and SIGCONT*
# to a process group that becomes orphaned while stopped, which is exactly what a
# closing terminal produces — and the command ignores SIGHUP, so only Guaranate's
# own relay and its wait can end this cleanly.
orphan_script="$(mktemp)"
cat >"$orphan_script" <<ORPHAN
set -m
"$BIN" while --reason "$reason21" /bin/sh -c "trap '' HUP; sleep 3" &
sleep 30
ORPHAN
script -q /dev/null /bin/bash --norc "$orphan_script" >/dev/null 2>&1 &
extra_pid=$!
wait_for_assertion "$reason21" present || fail "assertion never appeared"
session_pid=""
for _ in $(seq 1 50); do
  session_pid="$(pgrep -f "reason $reason21" | head -1)"
  [[ -n "$session_pid" ]] && break
  sleep 0.2
done
[[ -n "$session_pid" ]] || fail "could not find the session"
# The command's own pid, not a pattern match: it `exec`s, so its argv is its own
# and carries nothing of Guaranate's. Its pid is its process group, being the
# leader of one, which is what Ctrl+Z would signal.
child_pid=""
for _ in $(seq 1 50); do
  child_pid="$(pgrep -P "$session_pid" | head -1)"
  [[ -n "$child_pid" ]] && break
  sleep 0.2
done
[[ -n "$child_pid" ]] || fail "could not find the command under the session"
kill -TSTP "-$child_pid" 2>/dev/null || fail "could not stop the command's group"
# Both halves stopped is the state under test: the command by the signal, the
# session because it mirrors it.
for _ in $(seq 1 50); do
  [[ "$(ps -o state= -p "$child_pid" | tr -d ' ')" == T* \
     && "$(ps -o state= -p "$session_pid" | tr -d ' ')" == T* ]] && break
  sleep 0.2
done
[[ "$(ps -o state= -p "$child_pid" | tr -d ' ')" == T* ]] \
  || fail "the command did not stop"
[[ "$(ps -o state= -p "$session_pid" | tr -d ' ')" == T* ]] \
  || fail "the session did not mirror the command's stop"
assertion_present "$reason21" || fail "the assertion was dropped while the job was paused"
# The terminal goes away: kill the pty owner, orphaning both stopped groups.
kill -KILL "$extra_pid" 2>/dev/null || true
wait "$extra_pid" 2>/dev/null || true
extra_pid=""
wait_for_assertion "$reason21" absent || fail "a stopped session held the assertion after losing its terminal"
# Liveness by pid: a SIGHUP-ignoring command left behind is exactly the orphan
# this must never produce, and it would not answer to any pattern.
for _ in $(seq 1 50); do kill -0 "$child_pid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$child_pid" 2>/dev/null; then
  kill -CONT "$child_pid" 2>/dev/null || true
  kill -KILL "$child_pid" 2>/dev/null || true
  rm -f "$orphan_script"
  fail "the command was orphaned by the lost terminal"
fi
rm -f "$orphan_script"
echo "  ✓ both halves stopped, assertion held while paused"
echo "  ✓ the kernel's continue is enough: relayed, waited for, released"
echo "  ✓ no orphan, no stale assertion"

# --- Test 22: dispositions the caller chose are the command's, not ours ---------
echo
echo "▸ Test 22: while (a signal the caller ignores stays ignored in the command)"
# Both halves are measured against the same command run without Guaranate, so the
# contract under test is fidelity itself rather than a particular exit code.
base_ignored=0
( trap '' TERM
  /bin/sh -c "kill -TERM \$\$; exit 0" ) || base_ignored=$?
status=0
( trap '' TERM
  "$BIN" while --reason "$tag-inherit" /bin/sh -c "kill -TERM \$\$; exit 0" 2>/dev/null ) || status=$?
(( status == base_ignored )) \
  || fail "with SIGTERM ignored by the caller: wrapped exited $status, unwrapped $base_ignored"
(( base_ignored == 0 )) \
  || fail "the baseline command did not survive a SIGTERM its caller ignores (exit $base_ignored)"
echo "  ✓ an inherited ignore is the caller's choice, and survives the wrapper"

# And a disposition Guaranate did take over must still be reset, so the command is
# not left deaf to a signal it would have received.
base_default=0
/bin/sh -c "kill -TERM \$\$; exit 0" || base_default=$?
status=0
"$BIN" while --reason "$tag-inherit-dfl" /bin/sh -c "kill -TERM \$\$; exit 0" 2>/dev/null || status=$?
(( status == base_default )) \
  || fail "with the default disposition: wrapped exited $status, unwrapped $base_default"
(( base_default == 143 )) || fail "expected the baseline command to die of SIGTERM, got $base_default"
echo "  ✓ a default disposition still reaches the command (exit $base_default)"

# --- Test 23: resuming a job re-decides who owns the terminal ------------------
echo
echo "▸ Test 23: while (fg takes the terminal back, bg leaves it with the shell)"
# Ownership has to be re-decided on every resume: `fg` hands the terminal to the
# command, `bg` keeps it for the shell. A session that assumes it still owns what
# it owned before the pause takes the terminal away from the shell it was handed
# back to, and keystrokes meant for the prompt go to a background job instead.
#
# This needs a shell that offers `fg`/`bg`, which a script cannot be: a
# non-interactive shell blocks forever on a stopped foreground job. The probe does
# what a shell does, without one — see scripts/job-control-probe.py.
probe="$repo_root/scripts/job-control-probe.py"
if ! command -v python3 >/dev/null 2>&1; then
  echo "  - skipped: python3 is unavailable to simulate job control"
else
  for mode in fg bg; do
    reason23="$tag-while-$mode"
    probe_out="$(mktemp)"
    python3 "$probe" "$BIN" "$reason23" "$mode" /bin/sh -c 'sleep 10' >"$probe_out" 2>&1 || true
    reading() { grep -o "$1=[0-9a-zA-Z+]*" "$probe_out" | head -1 | cut -d= -f2; }
    shell_pgid="$(reading SHELL)"
    command_pgid="$(reading COMMANDGROUP)"
    foreground="$(reading FOREGROUND)"
    [[ -n "$shell_pgid" && -n "$command_pgid" && -n "$foreground" ]] \
      || fail "the $mode probe produced no reading: $(tr '\n' ' ' <"$probe_out")"
    [[ "$(reading STOPPED_SESSION)" == T* ]] || fail "the session did not stop before $mode"
    [[ "$(reading STOPPED_COMMAND)" == T* ]] || fail "the command did not stop before $mode"
    grep -q "ALIVE=yes" "$probe_out" || fail "the command did not survive being resumed by $mode"
    if [[ "$mode" == fg ]]; then
      (( foreground == command_pgid )) \
        || fail "fg did not hand the terminal to the command (foreground $foreground)"
    else
      (( foreground != command_pgid )) \
        || fail "a backgrounded command took the terminal (foreground $foreground)"
      (( foreground == shell_pgid )) \
        || fail "the terminal left the shell: foreground $foreground, shell $shell_pgid"
    fi
    rm -f "$probe_out"
    wait_for_assertion "$reason23" absent || fail "stale assertion '$reason23' left behind"
  done
  echo "  ✓ fg hands the terminal to the command, bg leaves it with the shell"
  echo "  ✓ the command keeps running either way, no stale assertion"
fi

echo
echo "✓ smoke test passed"

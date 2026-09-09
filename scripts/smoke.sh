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
"$BIN" while --reason "$reason5" /bin/sleep 30 >/dev/null 2>&1 &
child_pid=$!

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

echo
echo "✓ smoke test passed"

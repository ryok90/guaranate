#!/usr/bin/env bash
#
# End-to-end smoke test for the guaranate binary.
#
# Drives the real CLI against the native IOKit power-assertion API and verifies
# the non-negotiable: no exit path may leave a stale assertion. Covers timed
# expiry (exit 0), SIGINT (exit 130), `while` (command lifetime, exit-status
# propagation, signal forwarding, orphan-free teardown), and `--watch` (releases
# on the watched process's exit, detaches without killing it). This lives here
# (not in `swift test`) because it mutates the host's real sleep state via IOKit,
# which XCTest must never do (see AGENTS.md "Testing conventions").
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

echo
echo "✓ smoke test passed"

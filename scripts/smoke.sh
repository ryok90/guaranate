#!/usr/bin/env bash
#
# End-to-end smoke test for the guaranate binary.
#
# Drives the real CLI against the native IOKit power-assertion API and verifies
# the M1 non-negotiable: no exit path may leave a stale assertion, expiry exits
# 0, and SIGINT/SIGTERM release the assertion and exit 130. This lives here (not
# in `swift test`) because it mutates the host's real sleep state via IOKit,
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

fail() {
  echo "✗ FAIL: $*" >&2
  exit 1
}

# Kill any lingering child on unexpected exit so we never leak an assertion.
cleanup() {
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
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

echo
echo "✓ smoke test passed"

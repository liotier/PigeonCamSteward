#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_pulse_bridge.sh - lib/pigeoncam-common.sh's resolve_pulse_bridge_env():
# exports PULSE_SERVER/PULSE_COOKIE pointing at another user's PipeWire/
# PulseAudio session (needed because every unit in this project runs as
# root, which has no session of its own - FR6, SPEC.md §6a audio table),
# and fails cleanly with nothing exported when that user or their session
# doesn't exist, rather than silently connecting to nothing.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/pigeoncam-common.sh
source "$REPO_ROOT/lib/pigeoncam-common.sh"

echo "=== test_pulse_bridge.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REAL_USER=$(id -un)
REAL_UID=$(id -u)
FAKE_RUNTIME_BASE="$WORK/run-user"
mkdir -p "$FAKE_RUNTIME_BASE/$REAL_UID/pulse"
python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
" "$FAKE_RUNTIME_BASE/$REAL_UID/pulse/native"

# --- happy path: real user, socket present under the override base -------
unset PULSE_SERVER PULSE_COOKIE
PIGEONCAM_PULSE_RUNTIME_BASE="$FAKE_RUNTIME_BASE" resolve_pulse_bridge_env "$REAL_USER"
rc=$?
assert_eq "0" "$rc" "happy path: resolves successfully when the socket exists"
assert_eq "unix:$FAKE_RUNTIME_BASE/$REAL_UID/pulse/native" "${PULSE_SERVER:-}" "happy path: PULSE_SERVER points at the right socket"
assert_contains "${PULSE_COOKIE:-}" "/.config/pulse/cookie" "happy path: PULSE_COOKIE points into the user's home"

# --- nonexistent user: fails, exports nothing -----------------------------
unset PULSE_SERVER PULSE_COOKIE
PIGEONCAM_PULSE_RUNTIME_BASE="$FAKE_RUNTIME_BASE" resolve_pulse_bridge_env "definitely_nonexistent_user_xyz"
rc=$?
assert_true "nonexistent user: returns non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_eq "" "${PULSE_SERVER:-}" "nonexistent user: PULSE_SERVER left unset"
assert_eq "" "${PULSE_COOKIE:-}" "nonexistent user: PULSE_COOKIE left unset"

# --- real user, but no session (socket missing): fails, exports nothing --
unset PULSE_SERVER PULSE_COOKIE
EMPTY_RUNTIME_BASE="$WORK/run-user-empty"
mkdir -p "$EMPTY_RUNTIME_BASE"
PIGEONCAM_PULSE_RUNTIME_BASE="$EMPTY_RUNTIME_BASE" resolve_pulse_bridge_env "$REAL_USER"
rc=$?
assert_true "no active session: returns non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_eq "" "${PULSE_SERVER:-}" "no active session: PULSE_SERVER left unset"

test_summary_and_exit

#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_ctl.sh - pigeoncam-ctl.sh: one command applies systemctl <verb> to
# every PigeonCamSteward unit (pigeoncam-stream.service plus the five
# pigeoncam-*.timer units) instead of the operator naming all six by hand.
# Checks: start/restart/enable act in PIGEONCAM_ALL_UNITS order and
# stop/disable act in reverse (the long-running stream service starts first
# and stops last); status reports each unit's active/enabled state and its
# exit code reflects whether every unit is actually up; one unit failing
# doesn't stop the rest from being attempted (apply()'s aggregate-and-report
# behavior, mirroring pigeoncam-doctor.sh's own "keep going" philosophy); and
# basic usage/argument handling.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_ctl.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SYSTEMCTL_LOG="$WORK/systemctl.log"

# run_ctl <verb> [active] [enabled_state] [fail_unit] - explicit params, not
# ambient env vars, for the same reason test_doctor.sh's run_doctor() takes
# them as args: a bare VAR=x prefix before out=$(...) never reaches the
# subprocess since that line has no trailing command word. Combines
# stdout+stderr since pigeoncam-ctl.sh deliberately puts its error-path
# messages on stderr (log_error) like every other script in this project.
run_ctl() {
    local verb="$1" active="${2:-active}" enabled_state="${3:-enabled}" fail_unit="${4:-}"
    : > "$SYSTEMCTL_LOG"
    PATH="$FAKE_BIN:$PATH" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_SYSTEMCTL_ACTIVE="$active" \
    FAKE_SYSTEMCTL_ENABLED_STATE="$enabled_state" \
    FAKE_SYSTEMCTL_FAIL_UNIT="$fail_unit" \
    "$REPO_ROOT/bin/pigeoncam-ctl.sh" "$verb" 2>&1
}

# verb_unit_sequence - the systemctl log with timestamps stripped, so tests
# can assert on exact call order/content independently of real time.
verb_unit_sequence() {
    cut -d' ' -f2- "$SYSTEMCTL_LOG"
}

FORWARD_START=$'start pigeoncam-stream.service\nstart pigeoncam-watchdog.timer\nstart pigeoncam-status-check.timer\nstart pigeoncam-rotate.timer\nstart pigeoncam-archive-trim.timer\nstart pigeoncam-ytdlp-update.timer'
REVERSE_STOP=$'stop pigeoncam-ytdlp-update.timer\nstop pigeoncam-archive-trim.timer\nstop pigeoncam-rotate.timer\nstop pigeoncam-status-check.timer\nstop pigeoncam-watchdog.timer\nstop pigeoncam-stream.service'
FORWARD_ENABLE=$'enable pigeoncam-stream.service\nenable pigeoncam-watchdog.timer\nenable pigeoncam-status-check.timer\nenable pigeoncam-rotate.timer\nenable pigeoncam-archive-trim.timer\nenable pigeoncam-ytdlp-update.timer'
REVERSE_DISABLE=$'disable pigeoncam-ytdlp-update.timer\ndisable pigeoncam-archive-trim.timer\ndisable pigeoncam-rotate.timer\ndisable pigeoncam-status-check.timer\ndisable pigeoncam-watchdog.timer\ndisable pigeoncam-stream.service'
FORWARD_RESTART=$'restart pigeoncam-stream.service\nrestart pigeoncam-watchdog.timer\nrestart pigeoncam-status-check.timer\nrestart pigeoncam-rotate.timer\nrestart pigeoncam-archive-trim.timer\nrestart pigeoncam-ytdlp-update.timer'

# --- start: forward order, stream service first --------------------------
out=$(run_ctl start); rc=$?
assert_eq "0" "$rc" "start: exits 0 when every unit succeeds"
assert_eq "$FORWARD_START" "$(verb_unit_sequence)" "start: applies to all 6 units in install order"

# --- stop: reverse order, stream service last -----------------------------
run_ctl stop >/dev/null; rc=$?
assert_eq "0" "$rc" "stop: exits 0 when every unit succeeds"
assert_eq "$REVERSE_STOP" "$(verb_unit_sequence)" "stop: applies in reverse order, stream service stopped last"

# --- enable: forward order, same as start ---------------------------------
run_ctl enable >/dev/null; rc=$?
assert_eq "0" "$rc" "enable: exits 0 when every unit succeeds"
assert_eq "$FORWARD_ENABLE" "$(verb_unit_sequence)" "enable: applies to all 6 units in install order"

# --- disable: reverse order, same as stop ---------------------------------
run_ctl disable >/dev/null; rc=$?
assert_eq "0" "$rc" "disable: exits 0 when every unit succeeds"
assert_eq "$REVERSE_DISABLE" "$(verb_unit_sequence)" "disable: applies in reverse order, stream service disabled last"

# --- restart: forward order ------------------------------------------------
run_ctl restart >/dev/null; rc=$?
assert_eq "0" "$rc" "restart: exits 0 when every unit succeeds"
assert_eq "$FORWARD_RESTART" "$(verb_unit_sequence)" "restart: applies to all 6 units in install order"

# --- status: everything healthy -------------------------------------------
out=$(run_ctl status); rc=$?
assert_eq "0" "$rc" "status: exits 0 when every unit is active and enabled"
assert_contains "$out" "pigeoncam-stream.service" "status: lists the stream service"
assert_contains "$out" "pigeoncam-ytdlp-update.timer" "status: lists the last timer"
assert_contains "$out" "active" "status: shows the active state"
assert_contains "$out" "enabled" "status: shows the enabled state"

# --- status: a unit that's stopped or not enabled is a non-zero exit ------
out=$(run_ctl status inactive enabled); rc=$?
assert_eq "1" "$rc" "status: exits non-zero when a unit is inactive"
out=$(run_ctl status active disabled); rc=$?
assert_eq "1" "$rc" "status: exits non-zero when a unit is not enabled"

# --- one unit failing doesn't stop the rest from being attempted ---------
out=$(run_ctl start active enabled "pigeoncam-rotate.timer"); rc=$?
assert_eq "1" "$rc" "start: exits non-zero when one unit fails"
assert_eq "6" "$(grep -c '^start ' <<<"$(verb_unit_sequence)")" "start: still attempts all 6 units even though one failed"
assert_contains "$out" "failed for: pigeoncam-rotate.timer" "start: reports which unit(s) failed"

# --- usage / argument handling --------------------------------------------
out=$(PATH="$FAKE_BIN:$PATH" FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" "$REPO_ROOT/bin/pigeoncam-ctl.sh" 2>&1); rc=$?
assert_eq "2" "$rc" "no verb: exits 2"
assert_contains "$out" "Usage:" "no verb: prints usage"

out=$(run_ctl bogus-verb); rc=$?
assert_eq "2" "$rc" "unknown verb: exits 2"
assert_contains "$out" "unknown argument: bogus-verb" "unknown verb: reports the bad argument"

out=$(run_ctl --help); rc=$?
assert_eq "0" "$rc" "--help: exits 0"
assert_contains "$out" "Usage:" "--help: prints usage"

test_summary_and_exit

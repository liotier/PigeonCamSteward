#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_watchdog.sh - acceptance criterion 4: simulating a stall (no frame
# progress within stall_timeout_seconds) results in the watchdog restarting
# the unit. Also exercises FR7b: a stall detected again on the very next
# check (i.e. the plain restart didn't clear it) escalates to a USB reset
# before restarting again, and a subsequent healthy check resets the
# escalation counter.
#
# Drives pigeoncam-watchdog.sh's real stall-detection logic directly (by
# controlling the progress file's mtime/content, exactly what a real stall
# - e.g. `kill -STOP` on ffmpeg - would produce) rather than actually
# stopping a real ffmpeg process, since there is no real capture pipeline
# in this environment. A fake systemctl records restart calls instead of
# managing real units, and a fake uhubctl lets the real
# pigeoncam-usb-reset.sh run end-to-end during the escalation case.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_watchdog.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SEGMENT_DIR="$WORK/archive"
RUN_DIR="$WORK/run"
mkdir -p "$SEGMENT_DIR" "$RUN_DIR"
KEY_FILE="$WORK/stream_key"
echo "dummy-key" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
CONFIG="$WORK/config.yaml"
write_test_config "$CONFIG" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
# short stall_timeout so the test doesn't wait a real 60s
sed -i 's/stall_timeout_seconds: 60/stall_timeout_seconds: 3/' "$CONFIG"

PROGRESS_FILE="$RUN_DIR/progress"
SYSTEMCTL_LOG="$WORK/systemctl.log"
UHUBCTL_LOG="$WORK/uhubctl.log"
: > "$SYSTEMCTL_LOG"
: > "$UHUBCTL_LOG"

run_watchdog() {
    local active="${1:-active}"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_SYSTEMCTL_ACTIVE="$active" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_UHUBCTL_MODE=succeed \
    "$REPO_ROOT/bin/pigeoncam-watchdog.sh"
}

restart_count() {
    # grep -c exits 1 (while still printing "0") when there are no matches,
    # so a naive `grep -c ... || echo 0` fallback double-prints; the log
    # file always exists here (pre-touched above), so just take grep's own
    # count and ignore its exit status.
    grep -c 'restart pigeoncam-stream.service' "$SYSTEMCTL_LOG" 2>/dev/null
    true
}

# --- no progress file yet: must not crash, must not restart --------------
rm -f "$PROGRESS_FILE"
run_watchdog
assert_eq "0" "$(restart_count)" "no progress file yet (startup): no restart issued"

# --- unit not active (mid-rotation-gap, or a deliberate maintenance stop):
#     a stale progress file must NOT be treated as a stall - the unit isn't
#     hung, it's stopped, and this is exactly what would otherwise fight
#     restart-mode rotation's deliberate stop -> gap -> start window -------
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out_inactive=$(run_watchdog inactive 2>&1)
assert_eq "0" "$(restart_count)" "unit not active: a stale progress file triggers no restart"
assert_contains "$out_inactive" "not active" "unit not active: logged clearly, not silently skipped"

# --- healthy: fresh progress file, recent write -> no restart ------------
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
run_watchdog
assert_eq "0" "$(restart_count)" "fresh/healthy progress file: no restart issued"

# --- stall #1: progress file stale beyond stall_timeout_seconds ----------
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out1=$(run_watchdog 2>&1)
assert_eq "1" "$(restart_count)" "criterion 4: stall detected -> exactly one restart issued"
assert_contains "$out1" "STALL_RESTART" "criterion 4: restart is logged under the STALL_RESTART label (FR8)"
assert_true "FR7b: no USB reset yet after only one stall (uhubctl log still empty)" \
    bash -c "[ ! -s '$UHUBCTL_LOG' ]"

# --- stall #2, immediately: the restart did not clear it -> escalate -----
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out2=$(run_watchdog 2>&1)
assert_eq "2" "$(restart_count)" "FR7b: escalation cycle still restarts the stream after the USB reset"
assert_contains "$out2" "USB_RESET_ESCALATION" "FR7b: second consecutive stall escalates to a USB reset"
assert_true "FR7b: uhubctl was actually invoked during escalation" bash -c "[ -s '$UHUBCTL_LOG' ]"

# --- recovery: healthy check resets the escalation counter ---------------
printf 'frame=999\nprogress=continue\n' > "$PROGRESS_FILE"
run_watchdog
assert_eq "2" "$(restart_count)" "recovery: a healthy check issues no further restart"
: > "$UHUBCTL_LOG"

# stall again, once, after a recovery: must be a PLAIN restart, not an
# immediate re-escalation - proves the escalation counter really reset.
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out3=$(run_watchdog 2>&1)
assert_eq "3" "$(restart_count)" "post-recovery stall: another restart is issued"
assert_true "post-recovery stall does NOT immediately re-escalate (counter was reset by recovery)" \
    bash -c "[ ! -s '$UHUBCTL_LOG' ]"
assert_contains "$out3" "STALL_RESTART" "post-recovery stall is logged as a plain restart, not an escalation"

test_summary_and_exit

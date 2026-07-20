#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_watchdog.sh - acceptance criterion 4: simulating a stall (no frame
# progress within stall_timeout_seconds) results in the watchdog restarting
# the unit. Also exercises FR7b: a stall detected again on the very next
# check (i.e. the plain restart didn't clear it) escalates to a USB reset
# before restarting again, and a subsequent healthy check resets the
# escalation counter. Also A4: a cooldown between two USB resets, so a
# stall a reset genuinely can't fix doesn't re-trigger FR7b every other
# check forever - blocked escalations still fall back to a plain restart.
# Also C2: notify_command fires on a genuine escalation (label/message as
# $1/$2), and a failing notify_command never breaks the escalation itself.
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
# short usb_reset cooldown (config.example.yaml's real default is 300s) so
# the cooldown scenario below doesn't need a real five-minute wait; it
# still exercises the same code path via a shorter, deterministic window.
sed -i '/usb_path: ""/a\    cooldown_seconds: 10' "$CONFIG"

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

# --- A4: escalation-eligible again (the post-recovery stall above pushed
#     stall_restart_count back up to escalate_after), but the FR7b
#     escalation just above happened only moments ago, well inside the 10s
#     cooldown configured at the top of this test - must fall back to a
#     plain restart rather than firing uhubctl again -----------------------
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out4=$(run_watchdog 2>&1)
assert_eq "4" "$(restart_count)" "cooldown active: plain restart still happens even when escalation is blocked"
assert_true "cooldown active: blocked escalation does not invoke uhubctl again" \
    bash -c "[ ! -s '$UHUBCTL_LOG' ]"
assert_contains "$out4" "cooldown active" "cooldown active: the block is logged clearly, not silently skipped"

# --- A4: once the cooldown has actually elapsed, escalation fires again --
#     (state file backdated rather than sleeping out a real 10s, same
#     backdating discipline used for mtime freshness checks elsewhere in
#     this suite) ------------------------------------------------------
STATE_FILE="$RUN_DIR/watchdog.state"
assert_true "watchdog state file exists to backdate for the cooldown-elapsed case" \
    bash -c "[ -f '$STATE_FILE' ]"
sed -i "s/^last_usb_reset_epoch=.*/last_usb_reset_epoch=$(( $(date +%s) - 20 ))/" "$STATE_FILE"

printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out5=$(run_watchdog 2>&1)
assert_eq "5" "$(restart_count)" "cooldown elapsed: restart still happens"
assert_contains "$out5" "USB_RESET_ESCALATION" "cooldown elapsed: escalation fires again once past the cooldown"
assert_true "cooldown elapsed: uhubctl is invoked again" bash -c "[ -s '$UHUBCTL_LOG' ]"

# --- C2: notify_command fires on a genuine escalation, receiving the
#     event label/message as $1/$2 (only if the command template actually
#     references them, exactly as documented in config.example.yaml -
#     notify_escalation forwards them as $1/$2 to `sh -c`, it does not
#     append them to a bare command by itself) -----------------------------
NOTIFY_LOG="$WORK/notify.log"
NOTIFY_SCRIPT="$WORK/fake-notify.sh"
cat > "$NOTIFY_SCRIPT" <<EOF
#!/usr/bin/env bash
echo "LABEL=\$1 MESSAGE=\$2" >> "$NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_SCRIPT"
# Appended (order doesn't matter to yq's dotted-path lookups), template
# explicitly forwards "$1" "$2" - the heredoc's own \" / \$ escaping is
# what makes the *literal* characters `\"` and `$1`/`$2` land in the YAML
# file, so yq later hands notify_escalation the un-escaped shell template
# `.../fake-notify.sh "$1" "$2"`.
cat >> "$CONFIG" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

# One plain restart to bring stall_restart_count back to escalate_after,
# then past the cooldown too (backdated, same discipline as above), so
# the second stall actually escalates.
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
run_watchdog >/dev/null 2>&1
sed -i "s/^last_usb_reset_epoch=.*/last_usb_reset_epoch=$(( $(date +%s) - 20 ))/" "$STATE_FILE"
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
run_watchdog >/dev/null 2>&1

assert_true "C2: notify_command was invoked on a genuine escalation" bash -c "[ -s '$NOTIFY_LOG' ]"
notify_content=$(cat "$NOTIFY_LOG")
assert_contains "$notify_content" "LABEL=USB_RESET_ESCALATION" "C2: notify_command receives the event label as \$1"

# --- C2: a failing notify_command is a warning, never breaks the
#     escalation itself it's reporting on ----------------------------------
sed -i 's#^notify_command:.*#notify_command: "false"#' "$CONFIG"
: > "$UHUBCTL_LOG"
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
run_watchdog >/dev/null 2>&1
sed -i "s/^last_usb_reset_epoch=.*/last_usb_reset_epoch=$(( $(date +%s) - 20 ))/" "$STATE_FILE"
printf 'frame=10\nprogress=continue\n' > "$PROGRESS_FILE"
touch -d '10 seconds ago' "$PROGRESS_FILE"
out_notify_fail=$(run_watchdog 2>&1)

assert_contains "$out_notify_fail" "USB_RESET_ESCALATION" "C2: escalation still happens even though notify_command fails"
assert_true "C2: uhubctl is still invoked despite the failing notify_command" bash -c "[ -s '$UHUBCTL_LOG' ]"
assert_contains "$out_notify_fail" "notify_command failed" "C2: the failing notify_command is itself logged as a warning"

test_summary_and_exit

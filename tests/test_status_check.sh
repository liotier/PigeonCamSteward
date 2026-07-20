#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_status_check.sh - acceptance criteria 9, 10, 15 for FR7c/d/e:
#  - 15: a network/DNS/extractor failure classifies as INDETERMINATE and
#    never triggers a restart (only confirmed-not-live may).
#  - 9: confirmed-not-live with healthy local progress triggers a plain
#    restart (FR7d) and never touches the FR7b USB-reset path.
#  - 10: a recent rotation (or restart) suppresses action even if the
#    external check would otherwise call it not-live, so the two
#    mechanisms don't fight each other.
# Also exercises FR7e's escalation-and-backoff bookkeeping once
# max_restarts_before_escalation is reached, and recovery back to
# baseline on a subsequent confirmed-live result. Also C2: notify_command
# fires on the ESCALATION_UNAVAILABLE event specifically (not on every
# plain EXTERNAL_RESTART).

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_status_check.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SEGMENT_DIR="$WORK/archive"
RUN_DIR="$WORK/run"
mkdir -p "$SEGMENT_DIR" "$RUN_DIR"
KEY_FILE="$WORK/stream_key"
echo "dummy-key" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
CONFIG="$WORK/config.yaml"
# grace periods of 60s (not the real defaults): long enough that a
# just-written marker is reliably still "within grace" despite this
# script's own execution time (several yq/jq subprocess spawns), but the
# test never sleeps through it - "outside grace" scenarios below use
# markers minutes old instead of waiting. max_restarts_before_escalation=3,
# poll_interval=5 for a fast escalation/backoff sequence.
write_test_config "$CONFIG" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20

# C2: notify_command configured for the whole file - only the
# TIER2_ESCALATION/ESCALATION_UNAVAILABLE events below actually invoke it
# (see lib/pigeoncam-common.sh's notify_escalation), so this is inert for
# every other scenario in this file and doesn't need to be scoped per-test.
NOTIFY_LOG="$WORK/notify.log"
NOTIFY_SCRIPT="$WORK/fake-notify.sh"
cat > "$NOTIFY_SCRIPT" <<EOF
#!/usr/bin/env bash
echo "LABEL=\$1 MESSAGE=\$2" >> "$NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_SCRIPT"
cat >> "$CONFIG" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

PROGRESS_FILE="$RUN_DIR/progress"
SYSTEMCTL_LOG="$WORK/systemctl.log"
UHUBCTL_LOG="$WORK/uhubctl.log"
: > "$SYSTEMCTL_LOG"
: > "$UHUBCTL_LOG"

# Healthy local progress (fresh progress file) for the whole test, unless a
# scenario explicitly overrides it - FR7d only acts when local health is OK.
mark_local_healthy() { printf 'frame=100\nprogress=continue\n' > "$PROGRESS_FILE"; }
mark_local_healthy

# No started_at/last_rotation_at markers are written unless a scenario
# creates them - seconds_since_marker() then reports "never" (a very large
# number), i.e. always outside any grace period, which keeps most
# scenarios below independent of real wall-clock timing.

run_check() {
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE="$1" \
    FAKE_YTDLP_ID="${2:-VIDEO_A}" \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}

restart_count() { grep -c 'restart pigeoncam-stream.service' "$SYSTEMCTL_LOG" 2>/dev/null; true; }
STATE_FILE="$RUN_DIR/status-check.state"
reset_scenario() { : > "$SYSTEMCTL_LOG"; rm -f "$STATE_FILE"; }

# --- criterion 15: indeterminate never restarts ---------------------------
out=$(run_check indeterminate 2>&1)
assert_eq "0" "$(restart_count)" "criterion 15: indeterminate result triggers no restart"
assert_contains "$out" "INDETERMINATE" "criterion 15: indeterminate is logged as such"

out=$(run_check hang 2>&1)
assert_eq "0" "$(restart_count)" "criterion 15: yt-dlp hanging past its own timeout still triggers no restart"

# --- confirmed live: no action, state stays at baseline -------------------
out=$(run_check live VIDEO_A 2>&1)
assert_eq "0" "$(restart_count)" "confirmed live: no restart"

# --- criterion 9: confirmed not-live + healthy local -> plain restart,
#     never the FR7b USB-reset path -----------------------------------------
out=$(run_check not_live VIDEO_A 2>&1)
assert_eq "1" "$(restart_count)" "criterion 9: confirmed not-live triggers exactly one restart"
assert_contains "$out" "EXTERNAL_RESTART" "criterion 9: restart is logged under the EXTERNAL_RESTART label (FR8)"
assert_true "criterion 9: FR7b's USB-reset path was never touched" bash -c "[ ! -s '$UHUBCTL_LOG' ]"

# reset for the next scenarios - including consecutive_not_live, which
# criterion 9's restart above just incremented to 1
reset_scenario

# --- confirmed not-live but LOCAL health is bad -> defer to watchdog,
#     no action from this script at all -------------------------------------
touch -d '10 minutes ago' "$PROGRESS_FILE"   # stale well beyond any stall_timeout
out=$(run_check not_live VIDEO_A 2>&1)
assert_eq "0" "$(restart_count)" "local unhealthy: status-check defers to the watchdog and takes no action"
mark_local_healthy

# --- criterion 10: recent rotation suppresses action even if not-live ----
date +%s > "$RUN_DIR/last_rotation_at"
out=$(run_check not_live VIDEO_A 2>&1)
assert_eq "0" "$(restart_count)" "criterion 10: within post-rotation grace, no restart even though not-live"
assert_contains "$out" "grace period" "criterion 10: grace-period skip is logged"
rm -f "$RUN_DIR/last_rotation_at"

# a stale (long-past) rotation marker must NOT suppress action
date -d '1 hour ago' +%s > "$RUN_DIR/last_rotation_at"
out=$(run_check not_live VIDEO_A 2>&1)
assert_eq "1" "$(restart_count)" "an old rotation marker (grace long expired) does not suppress a real fault"
rm -f "$RUN_DIR/last_rotation_at" "$RUN_DIR/started_at"
reset_scenario

# --- FR7e: escalation once max_restarts_before_escalation is reached -----
run_check not_live VIDEO_A >/dev/null 2>&1   # attempt 1/3
run_check not_live VIDEO_A >/dev/null 2>&1   # attempt 2/3
out3=$(run_check not_live VIDEO_A 2>&1)      # attempt 3/3 -> escalation, not a plain restart
assert_eq "2" "$(restart_count)" "FR7e: only 2 plain restarts happen before the escalation threshold (3rd cycle escalates instead)"
assert_contains "$out3" "ESCALATION_UNAVAILABLE" "FR7e: escalation with Tier 2 absent logs a clear manual-intervention message"
assert_contains "$out3" "manual" "FR7e: the message actually mentions manual intervention"
assert_true "C2: notify_command was invoked on the ESCALATION_UNAVAILABLE event" bash -c "[ -s '$NOTIFY_LOG' ]"
assert_contains "$(cat "$NOTIFY_LOG")" "LABEL=ESCALATION_UNAVAILABLE" "C2: notify_command receives the ESCALATION_UNAVAILABLE label"

# next cycle: still not live, but backoff should suppress further action
out4=$(run_check not_live VIDEO_A 2>&1)
assert_eq "2" "$(restart_count)" "FR7e: no additional restart while backing off"
assert_contains "$out4" "backing off" "FR7e: backoff state is logged"

# --- recovery: confirmed live resets escalation/backoff state ------------
out5=$(run_check live VIDEO_A 2>&1)
assert_contains "$out5" "confirmed live" "recovery: confirmed-live is logged"
# after recovery, a fresh not-live sequence should again get 2 plain
# restarts before re-escalating, proving the counters actually reset
run_check not_live VIDEO_A >/dev/null 2>&1
out6=$(run_check not_live VIDEO_A 2>&1)
assert_contains "$out6" "EXTERNAL_RESTART" "recovery reset the counters: this is a plain restart, not an immediate re-escalation"

test_summary_and_exit

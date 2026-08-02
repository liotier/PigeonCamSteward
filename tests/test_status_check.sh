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

# --- frame-freeze (external_check.frame_freeze): a separate config with it
# enabled, check_interval_seconds=0 (every call is "due" for a fresh
# sample - real deployments default to 1800s, but a test can't wait that
# long) and confirm_count=2 (the shipped default). $CONFIG above keeps
# frame_freeze disabled (write_test_config's own default), used by the
# "disabled by default" scenario below.
CONFIG_FREEZE="$WORK/config-freeze.yaml"
write_test_config "$CONFIG_FREEZE" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i 's/^    enabled: false/    enabled: true/' "$CONFIG_FREEZE"

# run_check_freeze <hhmm> <url_mode> <frame_mode> [frame_bytes] - always
# is_live=true (the freeze check only ever runs once a broadcast is
# already confirmed live); PIGEONCAM_NOW_HHMM makes the daytime gate
# deterministic regardless of when this suite actually runs.
run_check_freeze() {
    local hhmm="$1" url_mode="$2" frame_mode="$3" frame_bytes="${4:-}"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG_FREEZE" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE=live \
    FAKE_YTDLP_ID=VIDEO_A \
    PIGEONCAM_NOW_HHMM="$hhmm" \
    FAKE_YTDLP_URL_MODE="$url_mode" \
    FAKE_FFMPEG_FRAME_MODE="$frame_mode" \
    FAKE_FFMPEG_FRAME_BYTES="$frame_bytes" \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}

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

# --- frame-freeze: disabled by default - identical frames every sample,
#     but the check never even runs, let alone restarts ------------------
reset_scenario
out=$(run_check live VIDEO_A 2>&1)
assert_eq "0" "$(restart_count)" "frame-freeze disabled (default): identical frames trigger nothing"
assert_contains "$out" "confirmed live" "frame-freeze disabled (default): still just a plain confirmed-live"
assert_not_contains "$out" "FROZEN" "frame-freeze disabled (default): the check doesn't even run"

# --- frame-freeze: enabled, daytime, identical frames reach confirm_count
#     (2) -> confirmed FROZEN, exactly one restart, labeled accordingly.
#     The first sample only ever establishes the baseline (nothing to
#     compare against yet), so 3 identical samples are needed to reach 2
#     *consecutive matches* ------------------------------------------------
reset_scenario
outf1=$(run_check_freeze 12:00 ok ok fixedFrame 2>&1)
assert_contains "$outf1" "confirmed live" "frame-freeze: sample 1/3 (baseline) - still just confirmed live"
assert_eq "0" "$(restart_count)" "frame-freeze: sample 1/3 - no restart yet"

outf2=$(run_check_freeze 12:00 ok ok fixedFrame 2>&1)
assert_contains "$outf2" "confirmed live" "frame-freeze: sample 2/3 (1 match, below confirm_count=2) - not frozen yet"
assert_eq "0" "$(restart_count)" "frame-freeze: sample 2/3 - no restart yet"

outf3=$(run_check_freeze 12:00 ok ok fixedFrame 2>&1)
assert_contains "$outf3" "confirmed FROZEN" "frame-freeze: sample 3/3 (2 consecutive matches) - confirmed frozen"
assert_eq "1" "$(restart_count)" "frame-freeze: confirmed frozen triggers exactly one restart"
assert_contains "$outf3" "EXTERNAL_RESTART" "frame-freeze: restart uses the same EXTERNAL_RESTART label as a not-live restart"
assert_contains "$outf3" "frozen" "frame-freeze: the restart's own message names the reason as frozen, not not-live"

# --- frame-freeze: the restart above must reset the freeze tracker - the
#     very next sample (even with the same, still-frozen bytes) is treated
#     as a fresh baseline, not an immediate second restart -----------------
outf4=$(run_check_freeze 12:00 ok ok fixedFrame 2>&1)
assert_contains "$outf4" "confirmed live" "frame-freeze: post-restart sample is a fresh baseline, not an immediate re-freeze"
assert_eq "1" "$(restart_count)" "frame-freeze: post-restart baseline sample issues no second restart"

# --- frame-freeze: enabled, daytime, but content genuinely changes every
#     sample - never frozen no matter how many samples --------------------
reset_scenario
run_check_freeze 12:00 ok ok frameA >/dev/null 2>&1
run_check_freeze 12:00 ok ok frameB >/dev/null 2>&1
run_check_freeze 12:00 ok ok frameC >/dev/null 2>&1
outc=$(run_check_freeze 12:00 ok ok frameD 2>&1)
assert_contains "$outc" "confirmed live" "frame-freeze: genuinely changing content never reports frozen"
assert_eq "0" "$(restart_count)" "frame-freeze: genuinely changing content never restarts"

# --- frame-freeze: THE false-positive this whole check had to avoid -
#     nighttime, identical frames every sample (a near-black scene with
#     little real sensor noise, exactly what's expected at night) - must
#     never be treated as frozen, no matter how many samples --------------
reset_scenario
run_check_freeze 02:00 ok ok fixedNight >/dev/null 2>&1
run_check_freeze 02:00 ok ok fixedNight >/dev/null 2>&1
outn=$(run_check_freeze 02:00 ok ok fixedNight 2>&1)
assert_contains "$outn" "confirmed live" "frame-freeze: identical nighttime frames are never reported frozen"
assert_not_contains "$outn" "FROZEN" "frame-freeze: nighttime never even logs a FROZEN determination"
assert_eq "0" "$(restart_count)" "frame-freeze: nighttime never restarts, however many identical samples"

# --- frame-freeze: a frame-grab failure counts neither as a match nor a
#     difference - it doesn't reset progress toward confirm_count, and it
#     doesn't fabricate progress towards it either ------------------------
reset_scenario
run_check_freeze 12:00 ok ok fixedFrame >/dev/null 2>&1        # sample 1/3: baseline
run_check_freeze 12:00 ok ok fixedFrame >/dev/null 2>&1        # sample 2/3: 1 match
outg=$(run_check_freeze 12:00 ok fail "" 2>&1)                 # grab fails: not counted
assert_contains "$outg" "could not grab a frame" "frame-freeze: a grab failure is logged as such"
assert_contains "$outg" "confirmed live" "frame-freeze: a grab failure alone is not treated as frozen"
assert_eq "0" "$(restart_count)" "frame-freeze: a grab failure alone triggers no restart"
outg2=$(run_check_freeze 12:00 ok ok fixedFrame 2>&1)          # sample 3/3: 2nd match - the failed sample didn't reset this
assert_contains "$outg2" "confirmed FROZEN" "frame-freeze: the failed sample didn't reset progress toward confirm_count - this one still completes it"
assert_eq "1" "$(restart_count)" "frame-freeze: confirmed frozen after the interrupted sequence still restarts exactly once"

# --- item 5 (2026-08-02 architecture review): sustained INDETERMINATE
#     eventually alerts, without ever weakening "indeterminate never
#     acts" (FR7c/acceptance criterion 15) - a low indeterminate_alert_after
#     (3, vs the real default 20) so this doesn't need 20 fake polls to
#     exercise the threshold. Reuses NOTIFY_SCRIPT/NOTIFY_LOG above -
#     scenarios below clear NOTIFY_LOG themselves before asserting on it. -
CONFIG_INDET="$WORK/config-indet.yaml"
write_test_config "$CONFIG_INDET" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i '/^  backoff_ceiling_seconds:/a\  indeterminate_alert_after: 3' "$CONFIG_INDET"
cat >> "$CONFIG_INDET" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

run_check_indet() {
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG_INDET" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE=indeterminate \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}
run_check_indet_live() {
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG_INDET" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE=live FAKE_YTDLP_ID=VIDEO_A \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}
blind_notice_count() { grep -c 'LABEL=EXTERNAL_CHECK_BLIND' "$NOTIFY_LOG" 2>/dev/null; true; }

# --- below threshold: no notification yet ---------------------------
reset_scenario
mark_local_healthy
: > "$NOTIFY_LOG"
run_check_indet >/dev/null 2>&1
out1=$(run_check_indet 2>&1)
assert_contains "$out1" "INDETERMINATE" "sustained indeterminate: still classified INDETERMINATE below threshold"
assert_eq "0" "$(blind_notice_count)" "sustained indeterminate: no EXTERNAL_CHECK_BLIND notice below threshold (2 of 3)"
assert_eq "0" "$(restart_count)" "sustained indeterminate: never triggers a restart, however many polls (invariant this item must not weaken)"

# --- exactly at threshold: exactly one notification -------------------
out2=$(run_check_indet 2>&1)
assert_contains "$out2" "EXTERNAL_CHECK_BLIND" "sustained indeterminate: fires at exactly the configured threshold (3)"
assert_eq "1" "$(blind_notice_count)" "sustained indeterminate: exactly one notice at threshold, not one per poll"
assert_eq "0" "$(restart_count)" "sustained indeterminate: still no restart even once the alert fires - detection only, never action"

# --- past threshold, before the next multiple: no additional notice ---
run_check_indet >/dev/null 2>&1
run_check_indet >/dev/null 2>&1
assert_eq "1" "$(blind_notice_count)" "sustained indeterminate: no additional notice between thresholds (4, 5 of 6)"

# --- re-arms at the next multiple, rather than never firing again -----
run_check_indet >/dev/null 2>&1
assert_eq "2" "$(blind_notice_count)" "sustained indeterminate: re-arms and fires again at the next multiple (6), rather than only ever once"

# --- any determinate outcome resets the counter - an indeterminate run
#     that's interrupted by so much as one confirmed-live poll must not
#     silently carry its progress toward the next threshold -------------
reset_scenario
mark_local_healthy
: > "$NOTIFY_LOG"
run_check_indet >/dev/null 2>&1
run_check_indet >/dev/null 2>&1          # 2 of 3 - one more would fire
run_check_indet_live >/dev/null 2>&1     # determinate (live): resets to 0
run_check_indet >/dev/null 2>&1
outr=$(run_check_indet 2>&1)             # only 2 of 3 again post-reset
assert_not_contains "$outr" "EXTERNAL_CHECK_BLIND" "sustained indeterminate: a determinate poll resets the counter - 2 more indeterminate polls after it must not reach the threshold"
assert_eq "0" "$(blind_notice_count)" "sustained indeterminate: confirms the reset, not a coincidence of timing"

# --- 0 disables the alert entirely, however many consecutive polls ----
CONFIG_INDET_OFF="$WORK/config-indet-off.yaml"
write_test_config "$CONFIG_INDET_OFF" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i '/^  backoff_ceiling_seconds:/a\  indeterminate_alert_after: 0' "$CONFIG_INDET_OFF"
cat >> "$CONFIG_INDET_OFF" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF
reset_scenario
mark_local_healthy
: > "$NOTIFY_LOG"
for _ in 1 2 3 4 5 6; do
    PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_INDET_OFF" \
        FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
        FAKE_YTDLP_MODE=indeterminate \
        "$REPO_ROOT/bin/pigeoncam-status-check.sh" >/dev/null 2>&1
done
assert_eq "0" "$(blind_notice_count)" "sustained indeterminate: indeterminate_alert_after=0 disables the alert entirely"

test_summary_and_exit

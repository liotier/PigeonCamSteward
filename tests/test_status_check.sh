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
DURABLE_DIR="$WORK/durable"
mkdir -p "$SEGMENT_DIR" "$RUN_DIR" "$DURABLE_DIR"
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
# YOUTUBE_API_ESCALATION/ESCALATION_UNAVAILABLE events below actually invoke it
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
SYSTEMD_RUN_LOG="$WORK/systemd-run.log"
: > "$SYSTEMCTL_LOG"
: > "$UHUBCTL_LOG"
: > "$SYSTEMD_RUN_LOG"

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
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE="$1" \
    FAKE_YTDLP_ID="${2:-VIDEO_A}" \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}

restart_count() { grep -c 'restart pigeoncam-stream.service' "$SYSTEMCTL_LOG" 2>/dev/null; true; }
STATE_FILE="$RUN_DIR/status-check.state"
# Also re-freshens the progress file (not just log/state): it's written
# once, at the top of this file, and stays untouched otherwise - harmless
# while this file was short, but the frame-border block added enough real
# subprocess-heavy invocations (yq/jq/ffmpeg per call) that the file's
# cumulative wall-clock runtime started crossing stall_timeout_seconds
# (60s) by the time later scenarios ran, making local_health_ok() report
# unhealthy and every check below it exit early - not what any of those
# scenarios were testing.
reset_scenario() { : > "$SYSTEMCTL_LOG"; rm -f "$STATE_FILE"; mark_local_healthy; }

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
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
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
# last_rotation_at is durable (item 3a) - started_at stays in RUN_DIR (tmpfs).
date +%s > "$DURABLE_DIR/last_rotation_at"
out=$(run_check not_live VIDEO_A 2>&1)
assert_eq "0" "$(restart_count)" "criterion 10: within post-rotation grace, no restart even though not-live"
assert_contains "$out" "grace period" "criterion 10: grace-period skip is logged"
rm -f "$DURABLE_DIR/last_rotation_at"

# a stale (long-past) rotation marker must NOT suppress action
date -d '1 hour ago' +%s > "$DURABLE_DIR/last_rotation_at"
out=$(run_check not_live VIDEO_A 2>&1)
assert_eq "1" "$(restart_count)" "an old rotation marker (grace long expired) does not suppress a real fault"
rm -f "$DURABLE_DIR/last_rotation_at" "$RUN_DIR/started_at"
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

# --- sustained frame-sampling failure eventually alerts. The gap this
#     closes was real and silent: every fetch failed for three and a half
#     days in the field while the is-live check kept working normally, so
#     frame_freeze AND frame_border were both blind the whole time with
#     nothing but an INFO line to show for it. Like the indeterminate
#     alert, this must never ACT - a frame that can't be fetched says
#     nothing about whether the stream is healthy. Threshold lowered to 3
#     (vs the shipped 10) so this doesn't need 10 fake polls. -----------
CONFIG_BLIND="$WORK/config-blind.yaml"
write_test_config "$CONFIG_BLIND" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i -e 's/^    enabled: false/    enabled: true/' \
       -e 's/^  sample_failure_alert_after: 10/  sample_failure_alert_after: 3/' "$CONFIG_BLIND"
cat >> "$CONFIG_BLIND" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

# run_check_blind <hhmm> <url_mode> <frame_mode> [frame_bytes]
run_check_blind() {
    PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_BLIND" PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE=live FAKE_YTDLP_ID=VIDEO_A PIGEONCAM_NOW_HHMM="$1" \
    FAKE_YTDLP_URL_MODE="$2" FAKE_FFMPEG_FRAME_MODE="$3" FAKE_FFMPEG_FRAME_BYTES="${4:-}" \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}
blind_sample_count() { grep -c 'LABEL=FRAME_SAMPLING_BLIND' "$NOTIFY_LOG" 2>/dev/null; true; }

# below threshold: no notice yet
reset_scenario
: > "$NOTIFY_LOG"
run_check_blind 12:00 fail ok >/dev/null 2>&1
outs=$(run_check_blind 12:00 fail ok 2>&1)
assert_contains "$outs" "could not resolve a media URL" "sampling blind: a resolve failure is still logged per attempt"
assert_eq "0" "$(blind_sample_count)" "sampling blind: no notice below the threshold (2 of 3)"

# exactly at threshold: exactly one notice, and still no action taken
outs3=$(run_check_blind 12:00 fail ok 2>&1)
assert_contains "$outs3" "FRAME_SAMPLING_BLIND" "sampling blind: fires at exactly the configured threshold"
assert_eq "1" "$(blind_sample_count)" "sampling blind: exactly one notice at threshold, not one per attempt"
assert_eq "0" "$(restart_count)" "sampling blind: detection only - never restarts, however many fetches fail"
assert_contains "$(cat "$NOTIFY_LOG")" "health layers are blind" "sampling blind: the message says a sensor is blind, not that the stream is broken"

# re-arms at the next multiple rather than going quiet forever
run_check_blind 12:00 fail ok >/dev/null 2>&1
run_check_blind 12:00 fail ok >/dev/null 2>&1
assert_eq "1" "$(blind_sample_count)" "sampling blind: no extra notice between thresholds (4, 5 of 6)"
run_check_blind 12:00 fail ok >/dev/null 2>&1
assert_eq "2" "$(blind_sample_count)" "sampling blind: re-arms and fires again at the next multiple"

# a single successful fetch resets the streak - an outage interrupted by
# one good sample must not carry its progress toward the next threshold
reset_scenario
: > "$NOTIFY_LOG"
run_check_blind 12:00 fail ok >/dev/null 2>&1
run_check_blind 12:00 fail ok >/dev/null 2>&1          # 2 of 3
run_check_blind 12:00 ok ok frameOK >/dev/null 2>&1    # a frame arrives: reset
run_check_blind 12:00 fail ok >/dev/null 2>&1
outr=$(run_check_blind 12:00 fail ok 2>&1)             # only 2 of 3 again
assert_not_contains "$outr" "FRAME_SAMPLING_BLIND" "sampling blind: one successful fetch resets the streak"
assert_eq "0" "$(blind_sample_count)" "sampling blind: confirms the reset rather than a timing coincidence"

# a grab failure (fetch resolved, decode failed) counts the same way
reset_scenario
: > "$NOTIFY_LOG"
run_check_blind 12:00 ok fail >/dev/null 2>&1
run_check_blind 12:00 ok fail >/dev/null 2>&1
outgf=$(run_check_blind 12:00 ok fail 2>&1)
assert_contains "$outgf" "FRAME_SAMPLING_BLIND" "sampling blind: a failed frame GRAB counts toward the same alert, not just a failed resolve"

# 0 disables it entirely
CONFIG_BLIND_OFF="$WORK/config-blind-off.yaml"
write_test_config "$CONFIG_BLIND_OFF" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i -e 's/^    enabled: false/    enabled: true/' \
       -e 's/^  sample_failure_alert_after: 10/  sample_failure_alert_after: 0/' "$CONFIG_BLIND_OFF"
cat >> "$CONFIG_BLIND_OFF" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF
reset_scenario
: > "$NOTIFY_LOG"
for _ in 1 2 3 4 5 6; do
    PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_BLIND_OFF" PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE=live FAKE_YTDLP_ID=VIDEO_A PIGEONCAM_NOW_HHMM=12:00 \
    FAKE_YTDLP_URL_MODE=fail FAKE_FFMPEG_FRAME_MODE=ok \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh" >/dev/null 2>&1
done
assert_eq "0" "$(blind_sample_count)" "sampling blind: sample_failure_alert_after=0 disables the alert entirely"

# --- frame-border (external_check.frame_border): piggybacks entirely on
#     frame_freeze's own fetch cycle, so every config below also has
#     frame_freeze enabled (except the dependency scenario at the very
#     end, which deliberately doesn't). check_interval_seconds=0 as above.
#     frame_bytes is varied on every single call across every scenario in
#     this whole block, on purpose: identical bytes would let
#     frame_freeze's OWN confirm_count also reach threshold and add its
#     own FROZEN/restart into these assertions, which have nothing to do
#     with what's being tested here.
CONFIG_BORDER_OFF="$WORK/config-border-off.yaml"
write_test_config "$CONFIG_BORDER_OFF" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i 's/^    enabled: false/    enabled: true/' "$CONFIG_BORDER_OFF"

CONFIG_BORDER_WARN="$WORK/config-border-warn.yaml"
write_test_config "$CONFIG_BORDER_WARN" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i 's/^    enabled: false/    enabled: true/' "$CONFIG_BORDER_WARN"
sed -i 's/^    mode: off/    mode: warn/' "$CONFIG_BORDER_WARN"

CONFIG_BORDER_ROTATE="$WORK/config-border-rotate.yaml"
write_test_config "$CONFIG_BORDER_ROTATE" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i 's/^    enabled: false/    enabled: true/' "$CONFIG_BORDER_ROTATE"
sed -i 's/^    mode: off/    mode: rotate/' "$CONFIG_BORDER_ROTATE"

CONFIG_BORDER_NO_FREEZE="$WORK/config-border-no-freeze.yaml"
write_test_config "$CONFIG_BORDER_NO_FREEZE" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i 's/^    mode: off/    mode: rotate/' "$CONFIG_BORDER_NO_FREEZE"   # frame_freeze left disabled

# All four need their own notify_command - write_test_config doesn't set
# one, and several scenarios below assert on NOTIFY_LOG directly (mode:
# warn's whole visible effect IS the notification, unlike frame_freeze's
# restart).
for f in "$CONFIG_BORDER_OFF" "$CONFIG_BORDER_WARN" "$CONFIG_BORDER_ROTATE" "$CONFIG_BORDER_NO_FREEZE"; do
    cat >> "$f" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF
done

# run_check_border <config> <hhmm> <border_mode> <frame_bytes> [systemd_run_mode]
run_check_border() {
    local config="$1" hhmm="$2" border_mode="$3" frame_bytes="$4" systemd_run_mode="${5:-ok}"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$config" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_SYSTEMD_RUN_LOG="$SYSTEMD_RUN_LOG" \
    FAKE_SYSTEMD_RUN_MODE="$systemd_run_mode" \
    FAKE_YTDLP_MODE=live \
    FAKE_YTDLP_ID=VIDEO_A \
    PIGEONCAM_NOW_HHMM="$hhmm" \
    FAKE_YTDLP_URL_MODE=ok \
    FAKE_FFMPEG_FRAME_MODE=ok \
    FAKE_FFMPEG_FRAME_BYTES="$frame_bytes" \
    FAKE_FFMPEG_BORDER_MODE="$border_mode" \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}
systemd_run_count() { grep -c . "$SYSTEMD_RUN_LOG" 2>/dev/null; true; }
border_notice_count() { grep -c 'LABEL=FRAME_BORDER' "$NOTIFY_LOG" 2>/dev/null; true; }

# --- mode: off (default), frame_freeze enabled - never analyzes the frame
#     at all, regardless of what it would have found -----------------------
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
outb1=$(run_check_border "$CONFIG_BORDER_OFF" 12:00 pillarbox frame1 2>&1)
assert_contains "$outb1" "confirmed live" "frame-border off: still just confirmed live"
assert_not_contains "$outb1" "FRAME_BORDER" "frame-border off: never even analyzes the frame"
assert_eq "0" "$(systemd_run_count)" "frame-border off: systemd-run is never invoked"

# --- mode: warn - confirm_count (2) consecutive bordered samples fires a
#     notice, never restarts, never invokes systemd-run --------------------
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
outw1=$(run_check_border "$CONFIG_BORDER_WARN" 12:00 pillarbox frame1 2>&1)
assert_contains "$outw1" "confirmed live" "frame-border warn: sample 1/2 - still just confirmed live"
assert_eq "0" "$(border_notice_count)" "frame-border warn: sample 1/2 - no notice yet"

outw2=$(run_check_border "$CONFIG_BORDER_WARN" 12:00 pillarbox frame2 2>&1)
assert_contains "$outw2" "FRAME_BORDER_WARN" "frame-border warn: sample 2/2 (confirm_count reached) - fires"
assert_eq "1" "$(border_notice_count)" "frame-border warn: exactly one notice"
assert_eq "0" "$(restart_count)" "frame-border warn: never restarts the stream service"
assert_eq "0" "$(systemd_run_count)" "frame-border warn: never invokes systemd-run"
assert_contains "$(cat "$NOTIFY_LOG")" "left:right:top:bottom=0.0833:0.0833:0.0000:0.0000" "frame-border warn: notification includes the actual reading"

# --- mode: warn - firing resets the tracker: the very next sample (even
#     still bordered) doesn't immediately re-fire --------------------------
outw3=$(run_check_border "$CONFIG_BORDER_WARN" 12:00 pillarbox frame3 2>&1)
assert_not_contains "$outw3" "FRAME_BORDER_WARN" "frame-border warn: post-fire sample is a fresh baseline, not an immediate re-fire"
assert_eq "1" "$(border_notice_count)" "frame-border warn: still just the one notice"

# --- mode: rotate - confirmed border launches pigeoncam-rotate.sh --force
#     via systemd-run, detached; never a plain systemctl restart ----------
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
run_check_border "$CONFIG_BORDER_ROTATE" 12:00 pillarbox frame1 >/dev/null 2>&1
outr2=$(run_check_border "$CONFIG_BORDER_ROTATE" 12:00 pillarbox frame2 2>&1)
assert_contains "$outr2" "FRAME_BORDER_ROTATE" "frame-border rotate: confirm_count reached - fires"
assert_eq "1" "$(border_notice_count)" "frame-border rotate: exactly one notice"
assert_eq "0" "$(restart_count)" "frame-border rotate: never a plain systemctl restart of the stream service"
assert_eq "1" "$(systemd_run_count)" "frame-border rotate: exactly one systemd-run invocation"
assert_contains "$(cat "$SYSTEMD_RUN_LOG")" "pigeoncam-rotate.sh" "frame-border rotate: launches pigeoncam-rotate.sh"
assert_contains "$(cat "$SYSTEMD_RUN_LOG")" "--force" "frame-border rotate: passes --force"
assert_not_contains "$(cat "$SYSTEMD_RUN_LOG")" "--on-calendar" "frame-border rotate: one-shot, not a recurring schedule (see docs/development/INCIDENTS.md)"

# --- mode: rotate - systemd-run itself failing to launch is logged, not
#     silently swallowed ---------------------------------------------------
reset_scenario
: > "$SYSTEMD_RUN_LOG"
run_check_border "$CONFIG_BORDER_ROTATE" 12:00 pillarbox frame1 fail >/dev/null 2>&1
outr3=$(run_check_border "$CONFIG_BORDER_ROTATE" 12:00 pillarbox frame2 fail 2>&1)
assert_contains "$outr3" "could not launch the forced rotation" "frame-border rotate: a systemd-run failure is logged, not silently dropped"

# --- a clean (unbordered) reading never fires, however many samples ------
reset_scenario
: > "$NOTIFY_LOG"
run_check_border "$CONFIG_BORDER_WARN" 12:00 clean frame1 >/dev/null 2>&1
run_check_border "$CONFIG_BORDER_WARN" 12:00 clean frame2 >/dev/null 2>&1
outc=$(run_check_border "$CONFIG_BORDER_WARN" 12:00 clean frame3 2>&1)
assert_contains "$outc" "confirmed live" "frame-border: a clean reading never fires, however many samples"
assert_eq "0" "$(border_notice_count)" "frame-border: confirmed via the notify log too"

# --- a failed border analysis counts neither as a match nor a difference -
#     doesn't advance progress toward confirm_count, doesn't reset it
#     either --------------------------------------------------------------
reset_scenario
: > "$NOTIFY_LOG"
run_check_border "$CONFIG_BORDER_WARN" 12:00 pillarbox frame1 >/dev/null 2>&1   # sample 1/2
outf=$(run_check_border "$CONFIG_BORDER_WARN" 12:00 fail frame2 2>&1)          # analysis fails: not counted
assert_contains "$outf" "could not analyze" "frame-border: an analysis failure is logged as such"
assert_not_contains "$outf" "FRAME_BORDER" "frame-border: a failure alone never fires"
outf2=$(run_check_border "$CONFIG_BORDER_WARN" 12:00 pillarbox frame3 2>&1)     # sample 2/2 - the failed sample didn't reset this
assert_contains "$outf2" "FRAME_BORDER_WARN" "frame-border: the failed sample didn't reset progress toward confirm_count - this one still completes it"

# --- the daytime gate is inherited from frame_freeze, not independently
#     re-implemented: nighttime bordered samples never trigger, however
#     many ---------------------------------------------------------------
reset_scenario
: > "$NOTIFY_LOG"
run_check_border "$CONFIG_BORDER_WARN" 02:00 pillarbox frame1 >/dev/null 2>&1
run_check_border "$CONFIG_BORDER_WARN" 02:00 pillarbox frame2 >/dev/null 2>&1
outn=$(run_check_border "$CONFIG_BORDER_WARN" 02:00 pillarbox frame3 2>&1)
assert_contains "$outn" "confirmed live" "frame-border: nighttime never even samples, inherited from frame_freeze's own gate"
assert_eq "0" "$(border_notice_count)" "frame-border: confirmed via the notify log too"

# --- depends on frame_freeze being enabled: mode: rotate with frame_freeze
#     disabled never fires, however bordered the frames - sample_frame_border
#     is simply never reached (pigeoncam-doctor.sh separately warns about
#     this combination) ----------------------------------------------------
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
run_check_border "$CONFIG_BORDER_NO_FREEZE" 12:00 pillarbox frame1 >/dev/null 2>&1
outd=$(run_check_border "$CONFIG_BORDER_NO_FREEZE" 12:00 pillarbox frame2 2>&1)
assert_contains "$outd" "confirmed live" "frame-border: frame_freeze disabled - the border check never even runs"
assert_eq "0" "$(systemd_run_count)" "frame-border: frame_freeze disabled - systemd-run never invoked even with mode: rotate"

# --- frame-border's own light gate (min_solar_altitude_degrees), on top
#     of the shared daytime gate above: uses extreme threshold values so
#     the outcome is deterministic regardless of when this suite actually
#     runs, rather than depending on real wall-clock "now" - the
#     underlying solar-altitude math itself is test_solar.sh's job, this
#     only proves the gate is correctly wired into sample_frame_border. -90
#     is below every real altitude (sin(-90)=-1, the minimum possible), so
#     it always passes; 89 is above anything reachable from Paris at any
#     time of year, so it never passes.
CONFIG_BORDER_LIGHT_OK="$WORK/config-border-light-ok.yaml"
write_test_config "$CONFIG_BORDER_LIGHT_OK" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i -e 's/^    enabled: false/    enabled: true/' \
       -e 's/^    mode: off/    mode: rotate/' \
       -e 's/latitude: ""/latitude: 48.8566/' \
       -e 's/longitude: ""/longitude: 2.3522/' \
       -e 's/^    min_solar_altitude_degrees: 6/    min_solar_altitude_degrees: -90/' \
    "$CONFIG_BORDER_LIGHT_OK"
cat >> "$CONFIG_BORDER_LIGHT_OK" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

CONFIG_BORDER_LIGHT_BLOCKED="$WORK/config-border-light-blocked.yaml"
write_test_config "$CONFIG_BORDER_LIGHT_BLOCKED" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i -e 's/^    enabled: false/    enabled: true/' \
       -e 's/^    mode: off/    mode: rotate/' \
       -e 's/latitude: ""/latitude: 48.8566/' \
       -e 's/longitude: ""/longitude: 2.3522/' \
       -e 's/^    min_solar_altitude_degrees: 6/    min_solar_altitude_degrees: 89/' \
    "$CONFIG_BORDER_LIGHT_BLOCKED"
cat >> "$CONFIG_BORDER_LIGHT_BLOCKED" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

CONFIG_BORDER_LIGHT_NOLOC="$WORK/config-border-light-noloc.yaml"
write_test_config "$CONFIG_BORDER_LIGHT_NOLOC" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" 150 60 60 5 3 20
sed -i -e 's/^    enabled: false/    enabled: true/' \
       -e 's/^    mode: off/    mode: rotate/' \
       -e 's/^    min_solar_altitude_degrees: 6/    min_solar_altitude_degrees: 89/' \
    "$CONFIG_BORDER_LIGHT_NOLOC"   # location deliberately left blank
cat >> "$CONFIG_BORDER_LIGHT_NOLOC" <<EOF
notify_command: "$NOTIFY_SCRIPT \"\$1\" \"\$2\""
EOF

# --- light gate open (-90, always passes): behaves exactly like the plain
#     rotate-mode test earlier in this block - a confirmed border fires -
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
run_check_border "$CONFIG_BORDER_LIGHT_OK" 12:00 pillarbox frame1 >/dev/null 2>&1
outlo=$(run_check_border "$CONFIG_BORDER_LIGHT_OK" 12:00 pillarbox frame2 2>&1)
assert_contains "$outlo" "FRAME_BORDER_ROTATE" "frame-border light gate open: a confirmed border still fires"
assert_eq "1" "$(systemd_run_count)" "frame-border light gate open: rotation is still launched"

# --- light gate closed (89, never passes): a confirmed-shape border never
#     even gets analyzed, however many bordered samples arrive - this is
#     the twilight false-positive fix itself (docs/development/INCIDENTS.md)
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
run_check_border "$CONFIG_BORDER_LIGHT_BLOCKED" 12:00 pillarbox frame1 >/dev/null 2>&1
run_check_border "$CONFIG_BORDER_LIGHT_BLOCKED" 12:00 pillarbox frame2 >/dev/null 2>&1
outlb=$(run_check_border "$CONFIG_BORDER_LIGHT_BLOCKED" 12:00 pillarbox frame3 2>&1)
assert_contains "$outlb" "confirmed live" "frame-border light gate closed: never fires, however many bordered samples arrive"
assert_eq "0" "$(border_notice_count)" "frame-border light gate closed: confirmed via the notify log too"
assert_eq "0" "$(systemd_run_count)" "frame-border light gate closed: no rotation is ever launched"

# --- light gate with no location configured: fails OPEN (no extra
#     restriction beyond the shared daytime gate), not closed ------------
reset_scenario
: > "$NOTIFY_LOG"
: > "$SYSTEMD_RUN_LOG"
run_check_border "$CONFIG_BORDER_LIGHT_NOLOC" 12:00 pillarbox frame1 >/dev/null 2>&1
outln=$(run_check_border "$CONFIG_BORDER_LIGHT_NOLOC" 12:00 pillarbox frame2 2>&1)
assert_contains "$outln" "FRAME_BORDER_ROTATE" "frame-border light gate: missing location fails open, not closed"
assert_eq "1" "$(systemd_run_count)" "frame-border light gate: missing location - rotation still launches"

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
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
    FAKE_YTDLP_MODE=indeterminate \
    "$REPO_ROOT/bin/pigeoncam-status-check.sh"
}
run_check_indet_live() {
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG_INDET" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
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
        PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
        FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_UHUBCTL_LOG="$UHUBCTL_LOG" \
        FAKE_YTDLP_MODE=indeterminate \
        "$REPO_ROOT/bin/pigeoncam-status-check.sh" >/dev/null 2>&1
done
assert_eq "0" "$(blind_notice_count)" "sustained indeterminate: indeterminate_alert_after=0 disables the alert entirely"

test_summary_and_exit

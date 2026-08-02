#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_rotate.sh - acceptance criterion 14: a rotation in restart mode
# observes the configured min_gap_seconds between stop and start, and the
# post-rotation check confirms a different video ID than before the
# rotation. Drives the real pigeoncam-rotate.sh with a fake systemctl
# (recording call timestamps) and a fake yt-dlp so pre/post ids are
# controllable without a real YouTube channel.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_rotate.sh ==="

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
MIN_GAP=3
write_test_config "$CONFIG" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" "$MIN_GAP"

SYSTEMCTL_LOG="$WORK/systemctl.log"

# --- scenario 1: broadcast id genuinely changes (rotation "worked") ------
: > "$SYSTEMCTL_LOG"
SEQ_FILE="$WORK/seq1"
rm -f "$SEQ_FILE"
out=$(
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_YTDLP_MODE=sequence \
    FAKE_YTDLP_SEQ_FILE="$SEQ_FILE" \
    PIGEONCAM_ROTATE_SETTLE_DELAY=1 \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1
)
rc=$?
assert_eq "0" "$rc" "rotate.sh exits 0 on a normal restart-mode rotation"

mapfile -t calls < <(grep -E 'stop pigeoncam-stream|start pigeoncam-stream' "$SYSTEMCTL_LOG")
assert_eq "2" "${#calls[@]}" "exactly one stop and one start were issued"
assert_contains "${calls[0]:-}" "stop pigeoncam-stream.service" "the stop call happens first"
assert_contains "${calls[1]:-}" "start pigeoncam-stream.service" "the start call happens second"

stop_ts=$(awk '{print $1}' <<<"${calls[0]:-0}")
start_ts=$(awk '{print $1}' <<<"${calls[1]:-0}")
gap=$(awk -v a="$stop_ts" -v b="$start_ts" 'BEGIN{printf "%d", (b-a)}')
assert_ge "$gap" "$MIN_GAP" "criterion 14: observed stop->start gap (${gap}s) is >= configured min_gap_seconds (${MIN_GAP}s)"

assert_contains "$out" "ROTATION_NEW_BROADCAST_ID" "criterion 14: rotation with a genuinely new id logs ROTATION_NEW_BROADCAST_ID"
assert_true "the last_rotation_at marker was written to the durable dir, not the tmpfs run dir (item 3a)" bash -c "[ -f '$DURABLE_DIR/last_rotation_at' ]"

# --- scenario 2: broadcast id does NOT change (the failure mode FR14/§5.4
#     warns about - a test SHOULD flag this loudly, not pass silently) ----
: > "$SYSTEMCTL_LOG"
# item 3b's age check would otherwise skip this rotation - scenario 1 just
# wrote a fresh last_rotation_at, and this scenario is testing rotation
# mechanics, not the age check (that gets its own scenarios further down).
rm -f "$DURABLE_DIR/last_rotation_at"
out2=$(
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_YTDLP_MODE=live \
    FAKE_YTDLP_ID=SAME_VIDEO \
    PIGEONCAM_ROTATE_SETTLE_DELAY=1 \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1
)
assert_contains "$out2" "ROTATION_SAME_BROADCAST_ID" \
    "an unchanged id is detected and logged as a warning (archive clock likely not reset)"

mapfile -t calls2 < <(grep -E 'stop pigeoncam-stream|start pigeoncam-stream' "$SYSTEMCTL_LOG")
stop_ts2=$(awk '{print $1}' <<<"${calls2[0]:-0}")
start_ts2=$(awk '{print $1}' <<<"${calls2[1]:-0}")
gap2=$(awk -v a="$stop_ts2" -v b="$start_ts2" 'BEGIN{printf "%d", (b-a)}')
assert_ge "$gap2" "$MIN_GAP" "the gap is still observed even when the same-id case is detected"

# --- scenario 3: api mode without Tier 2 installed -> clear error, no
#     stop/start ever issued (must not half-execute a rotation it can't
#     complete) --------------------------------------------------------
: > "$SYSTEMCTL_LOG"
rm -f "$DURABLE_DIR/last_rotation_at"   # see scenario 2's comment on item 3b
CONFIG_API="$WORK/config-api.yaml"
write_test_config "$CONFIG_API" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" "$MIN_GAP"
sed -i 's/mode: restart/mode: api/' "$CONFIG_API"
out3=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_API" PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1)
rc3=$?
assert_true "api mode without Tier 2 installed exits non-zero" bash -c "[ '$rc3' -ne 0 ]"
assert_contains "$out3" "Tier 2" "the error clearly names Tier 2 as missing"
assert_eq "0" "$(grep -cE 'stop pigeoncam-stream|start pigeoncam-stream' "$SYSTEMCTL_LOG" 2>/dev/null || true)" \
    "api mode never touches the running stream when Tier 2 isn't installed"

# --- scenario 4: api mode WITH Tier 2 installed -> hands off to
#     rotate_via_api.py AND writes last_rotation_at first, same as restart
#     mode (caught in review: do_api_rotation() delegated to Tier 2 without
#     ever writing the marker restart mode writes, leaving status-check's
#     grace period blind to the window api mode's own step 1 opens - the
#     prior broadcast is transitioned to complete before ffmpeg even
#     restarts, well before restart_stream()'s own started_at marker) -----
: > "$SYSTEMCTL_LOG"
rm -f "$DURABLE_DIR/last_rotation_at"   # see scenario 2's comment on item 3b
CONFIG_API2="$WORK/config-api2.yaml"
write_test_config "$CONFIG_API2" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" "$MIN_GAP"
sed -i 's/mode: restart/mode: api/' "$CONFIG_API2"
printf 'tier2:\n  enabled: true\n' >> "$CONFIG_API2"

# PIGEONCAM_API_DIR override (test-only, see lib/pigeoncam-common.sh) points
# tier2_available() at a throwaway fake venv+script instead of this
# checkout's real api/, so this test doesn't depend on - or risk touching -
# a real Tier 2 setup that might happen to exist in the same working copy.
FAKE_API_DIR="$WORK/fake-api"
mkdir -p "$FAKE_API_DIR/venv/bin"
cat > "$FAKE_API_DIR/venv/bin/python3" <<'FAKEPY'
#!/usr/bin/env bash
echo "FAKE_TIER2_ROTATION_INVOKED: $*"
FAKEPY
chmod +x "$FAKE_API_DIR/venv/bin/python3"
touch "$FAKE_API_DIR/rotate_via_api.py"

out4=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_API2" PIGEONCAM_API_DIR="$FAKE_API_DIR" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1)
assert_contains "$out4" "FAKE_TIER2_ROTATION_INVOKED" "api mode hands off to Tier 2's rotate_via_api.py when it's installed"
assert_true "api mode writes the last_rotation_at marker before handing off to Tier 2 (status-check's grace period must cover the whole not-live window, not just started_at partway through)" \
    bash -c "[ -f '$DURABLE_DIR/last_rotation_at' ]"

# --- scenario 5: api mode WITH Tier 2 installed, but the API call itself
#     fails - the real, field-confirmed incident this test guards against:
#     an expired OAuth refresh token made every scheduled rotation fail
#     with invalid_grant for over three days, completely silently (the
#     prior code `exec`'d into rotate_via_api.py, so a failure only ever
#     produced its own stderr line - no notify_command, nothing). Must now:
#     propagate the real exit code, log ROTATION_FAILED, and actually fire
#     notify_command (C2). -----------------------------------------------
: > "$SYSTEMCTL_LOG"
rm -f "$DURABLE_DIR/last_rotation_at"   # see scenario 2's comment on item 3b
NOTIFY_LOG5="$WORK/notify5.log"
NOTIFY_SCRIPT5="$WORK/fake-notify5.sh"
cat > "$NOTIFY_SCRIPT5" <<EOF
#!/usr/bin/env bash
echo "LABEL=\$1 MESSAGE=\$2" >> "$NOTIFY_LOG5"
EOF
chmod +x "$NOTIFY_SCRIPT5"

CONFIG_API5="$WORK/config-api5.yaml"
write_test_config "$CONFIG_API5" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" "$MIN_GAP"
sed -i 's/mode: restart/mode: api/' "$CONFIG_API5"
printf 'tier2:\n  enabled: true\n' >> "$CONFIG_API5"
cat >> "$CONFIG_API5" <<EOF
notify_command: "$NOTIFY_SCRIPT5 \"\$1\" \"\$2\""
EOF

FAKE_API_DIR5="$WORK/fake-api5"
mkdir -p "$FAKE_API_DIR5/venv/bin"
cat > "$FAKE_API_DIR5/venv/bin/python3" <<'FAKEPY'
#!/usr/bin/env bash
echo "ERROR token refresh failed: ('invalid_grant: Token has been expired or revoked.', ...)" >&2
exit 1
FAKEPY
chmod +x "$FAKE_API_DIR5/venv/bin/python3"
touch "$FAKE_API_DIR5/rotate_via_api.py"

out5=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_API5" PIGEONCAM_API_DIR="$FAKE_API_DIR5" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1)
rc5=$?
assert_eq "1" "$rc5" "a failed Tier 2 API rotation propagates the real exit code, not silently swallowed"
assert_contains "$out5" "ROTATION_FAILED" "a failed Tier 2 API rotation is logged as ROTATION_FAILED, not silent"
assert_true "a failed Tier 2 API rotation fires notify_command - the whole point, so a days-long silent outage can't recur unnoticed" \
    bash -c "[ -s '$NOTIFY_LOG5' ]"
assert_contains "$(cat "$NOTIFY_LOG5")" "LABEL=ROTATION_FAILED" "notify_command receives ROTATION_FAILED as the label"

# --- scenario 6: restart mode, systemctl stop itself fails (e.g. systemd
#     wedged) - same treatment, and start must never be attempted past a
#     failed stop (must not half-execute a rotation it can't complete). ----
: > "$SYSTEMCTL_LOG"
NOTIFY_LOG6="$WORK/notify6.log"
NOTIFY_SCRIPT6="$WORK/fake-notify6.sh"
cat > "$NOTIFY_SCRIPT6" <<EOF
#!/usr/bin/env bash
echo "LABEL=\$1 MESSAGE=\$2" >> "$NOTIFY_LOG6"
EOF
chmod +x "$NOTIFY_SCRIPT6"

CONFIG6="$WORK/config6.yaml"
write_test_config "$CONFIG6" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" "$MIN_GAP"
cat >> "$CONFIG6" <<EOF
notify_command: "$NOTIFY_SCRIPT6 \"\$1\" \"\$2\""
EOF

rm -f "$DURABLE_DIR/last_rotation_at"   # see scenario 2's comment on item 3b
out6=$(
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG6" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_SYSTEMCTL_FAIL_UNIT="pigeoncam-stream.service" \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1
)
rc6=$?
assert_true "restart-mode rotation exits non-zero when systemctl stop itself fails" bash -c "[ '$rc6' -ne 0 ]"
assert_contains "$out6" "ROTATION_FAILED" "a failed systemctl stop during rotation is logged as ROTATION_FAILED"
assert_true "notify_command fires when systemctl stop fails during rotation" bash -c "[ -s '$NOTIFY_LOG6' ]"
assert_eq "0" "$(grep -c 'start pigeoncam-stream' "$SYSTEMCTL_LOG" 2>/dev/null || true)" \
    "start is never attempted after a failed stop - must not half-execute past the failure"

# --- scenario 7: item 3b's age check - a marker older than the configured
#     interval (default youtube.rotation.interval: 11h45m) means a
#     rotation IS due, and proceeds normally --------------------------
: > "$SYSTEMCTL_LOG"
date -d '13 hours ago' +%s > "$DURABLE_DIR/last_rotation_at"
out7=$(
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    PIGEONCAM_ROTATE_SETTLE_DELAY=1 \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1
)
rc7=$?
assert_eq "0" "$rc7" "item 3b: a marker older than the interval - rotation proceeds and exits 0"
assert_not_contains "$out7" "not due yet" "item 3b: an overdue marker does not trigger the not-due skip message"
assert_eq "2" "$(grep -cE 'stop pigeoncam-stream|start pigeoncam-stream' "$SYSTEMCTL_LOG" 2>/dev/null || true)" \
    "item 3b: an overdue marker (13h ago > 11h45m interval) results in an actual stop+start"

# --- scenario 8: item 3b's age check - a marker younger than the
#     configured interval means a rotation is NOT due yet, and the whole
#     run is a clean no-op: the real fix for a reboot at hour 11 needing
#     pigeoncam-rotate.timer's OnBootSec lowered to 5min (see
#     systemd/pigeoncam-rotate.timer) without ALSO causing an unwanted
#     early rotation on every routine reboot ------------------------------
: > "$SYSTEMCTL_LOG"
date -d '1 hour ago' +%s > "$DURABLE_DIR/last_rotation_at"
out8=$(
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    PIGEONCAM_DURABLE_DIR="$DURABLE_DIR" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1
)
rc8=$?
assert_eq "0" "$rc8" "item 3b: a recent marker (1h ago < 11h45m interval) - the script exits 0 (a no-op is not a failure)"
assert_contains "$out8" "not due yet" "item 3b: a recent marker produces a clear 'not due yet' log line"
assert_eq "0" "$(grep -cE 'stop pigeoncam-stream|start pigeoncam-stream' "$SYSTEMCTL_LOG" 2>/dev/null || true)" \
    "item 3b: a recent marker means the stream is never touched - the whole point of the boot-age gate"

test_summary_and_exit

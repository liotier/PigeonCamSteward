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
mkdir -p "$SEGMENT_DIR" "$RUN_DIR"
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
assert_true "the last_rotation_at marker was written" bash -c "[ -f '$RUN_DIR/last_rotation_at' ]"

# --- scenario 2: broadcast id does NOT change (the failure mode FR14/§5.4
#     warns about - a test SHOULD flag this loudly, not pass silently) ----
: > "$SYSTEMCTL_LOG"
out2=$(
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
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
CONFIG_API="$WORK/config-api.yaml"
write_test_config "$CONFIG_API" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE" "$MIN_GAP"
sed -i 's/mode: restart/mode: api/' "$CONFIG_API"
out3=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_API" FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$REPO_ROOT/bin/pigeoncam-rotate.sh" 2>&1)
rc3=$?
assert_true "api mode without Tier 2 installed exits non-zero" bash -c "[ '$rc3' -ne 0 ]"
assert_contains "$out3" "Tier 2" "the error clearly names Tier 2 as missing"
assert_eq "0" "$(grep -cE 'stop pigeoncam-stream|start pigeoncam-stream' "$SYSTEMCTL_LOG" 2>/dev/null || true)" \
    "api mode never touches the running stream when Tier 2 isn't installed"

test_summary_and_exit

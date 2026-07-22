#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_reencode.sh - FR13's on-host bin/pigeoncam-reencode.sh, never
# previously exercised at all (reencode.enabled is false by default, and
# nothing in the shipped Quickstart turns it on). Drives it against a real
# ffmpeg/ffprobe round trip, same discipline as tests/test_offline_reencode.sh
# for its standalone counterpart - two of that script's three field-found
# bugs (ffmpeg unable to choose a muxer for a .reencode.tmp filename;
# ffprobe reporting MPEG-TS's video stream twice) turned out to affect this
# on-host script identically, and only ever showed up against real encoded
# output.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/bin/pigeoncam-reencode.sh"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_reencode.sh ==="

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "SKIP - ffmpeg not available"
    test_summary_and_exit
    exit $?
fi
encoders=$(ffmpeg -encoders 2>/dev/null)
if ! grep -q libx265 <<<"$encoders"; then
    echo "SKIP - ffmpeg with libx265 support not available"
    test_summary_and_exit
    exit $?
fi

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
# reencode.enabled: false is the only "enabled: false" line write_test_config
# generates - every other section's enabled key defaults to true there.
sed -i 's/enabled: false/enabled: true/' "$CONFIG"

video_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 -- "$1" 2>/dev/null | head -1
}

make_segment() {
    local dest="$1"
    ffmpeg -v error -f lavfi -i "testsrc=size=160x120:rate=5" -t 2 -map 0:v \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10 \
        -f mpegts "$dest" -y </dev/null
}

run_reencode() {
    PIGEONCAM_CONFIG="$CONFIG" "$SCRIPT"
}

# --- an old, closed segment gets re-encoded -------------------------------
OLD_SEGMENT="$SEGMENT_DIR/20260101_120000.ts"
make_segment "$OLD_SEGMENT"
touch -d '10 minutes ago' "$OLD_SEGMENT"
assert_eq "h264" "$(video_codec "$OLD_SEGMENT")" "fixture sanity: the old segment really is h264"

# --- a segment still being written (fresh mtime) is left alone -----------
FRESH_SEGMENT="$SEGMENT_DIR/20260101_130000.ts"
make_segment "$FRESH_SEGMENT"
# make_segment's own ffmpeg invocation already left a fresh mtime; no
# backdating needed - that's the point being tested.

out=$(run_reencode 2>&1); rc=$?
assert_eq "0" "$rc" "a normal run exits 0"
assert_contains "$out" "still being written" "the fresh segment is recognized as still being written"
assert_eq "h264" "$(video_codec "$FRESH_SEGMENT")" "the fresh (in-progress) segment is left untouched"
assert_eq "hevc" "$(video_codec "$OLD_SEGMENT")" "the old (closed) segment is re-encoded to hevc (libx265)"

# The write-then-mv-over-original pattern refreshes the file's own mtime
# (the temp file was just written by ffmpeg moments ago) - backdate again
# to simulate real time actually passing before the next scheduled run,
# isolating the "already encoded" skip tested below from the freshness
# skip tested above. In a real deployment this job runs at most daily;
# only this test's back-to-back timing makes the distinction matter.
touch -d '10 minutes ago' "$OLD_SEGMENT"

# --- a second run skips the now-already-encoded old segment, and still
#     leaves the fresh one alone --------------------------------------------
out2=$(run_reencode 2>&1)
assert_contains "$out2" "already hevc" "a second run recognizes the old segment is already re-encoded"
assert_contains "$out2" "still being written" "a second run still recognizes the fresh segment as in-progress"

# --- reencode.enabled: false is still honored (unrelated to the above,
#     but this script's only other branch and never otherwise covered).
#     Scoped to the reencode: block specifically (its own last section in
#     the generated config) - a blanket substitution would also flip
#     archive.enabled/usb_reset.enabled/external_check.enabled, all also
#     "true" in this fixture. -----------------------------------------
sed -i '/^reencode:/,$ s/enabled: true/enabled: false/' "$CONFIG"
out3=$(PIGEONCAM_CONFIG="$CONFIG" "$SCRIPT" 2>&1); rc3=$?
assert_eq "0" "$rc3" "reencode.enabled: false exits 0 (nothing to do, not an error)"
assert_contains "$out3" "nothing to do" "reencode.enabled: false is logged clearly"

test_summary_and_exit

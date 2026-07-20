#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_offline_reencode.sh - tools/pigeoncam-offline-reencode.sh: the
# standalone counterpart to bin/pigeoncam-reencode.sh (FR13), meant to run
# on a separate, stronger-CPU host against the archive directory mounted
# from the pigeon-cam. Drives it against a real ffmpeg/ffprobe round trip
# (not a mock) - the two bugs found while building this script (ffmpeg
# unable to choose a muxer for a .reencode.tmp filename; ffprobe reporting
# the same MPEG-TS video stream twice, breaking the already-encoded skip
# check) only ever showed up against real encoded output, exactly the kind
# of thing a mocked test can't catch.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
SCRIPT="$REPO_ROOT/tools/pigeoncam-offline-reencode.sh"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_offline_reencode.sh ==="

# Captured into a variable first, not piped straight to `grep -q`: under
# pipefail, grep -q's early exit on the first match SIGPIPEs ffmpeg
# before it finishes writing its full (multi-hundred-line) encoder list,
# which pipefail then reports as the pipeline failing even though grep
# found exactly what it was looking for (caught directly - this check
# reported "not available" every time despite libx265 being present).
encoders=$(ffmpeg -encoders 2>/dev/null)
if ! command -v ffmpeg >/dev/null 2>&1 || ! grep -q libx265 <<<"$encoders"; then
    echo "SKIP - ffmpeg with libx265 support not available"
    test_summary_and_exit
    exit $?
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

video_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 -- "$1" 2>/dev/null | head -1
}

SEGMENT="$WORK/20260101_120000.ts"
ffmpeg -v error -f lavfi -i "testsrc=size=160x120:rate=5" -t 2 -map 0:v \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10 \
    -f mpegts "$SEGMENT" -y </dev/null
assert_eq "h264" "$(video_codec "$SEGMENT")" "fixture sanity: the generated segment really is h264"

# --- missing/bad arguments -------------------------------------------------
out=$("$SCRIPT" 2>&1); rc=$?
assert_true "no directory argument exits non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "Usage:" "no directory argument shows usage"

out=$("$SCRIPT" "$WORK/does-not-exist" 2>&1); rc=$?
assert_true "nonexistent directory exits non-zero" bash -c "[ '$rc' -ne 0 ]"

# --- dry-run changes nothing -------------------------------------------------
out=$("$SCRIPT" --dry-run "$WORK" 2>&1)
assert_contains "$out" "would reencode" "--dry-run reports what it would do"
assert_eq "h264" "$(video_codec "$SEGMENT")" "--dry-run does not actually touch the file"

# --- a real run re-encodes to the target codec ------------------------------
out=$("$SCRIPT" "$WORK" 2>&1); rc=$?
assert_eq "0" "$rc" "a normal run exits 0"
assert_eq "hevc" "$(video_codec "$SEGMENT")" "the segment is now hevc (libx265) after re-encoding"

# --- a second run skips the now-already-encoded file, rather than
#     re-encoding (and quality-degrading) it again - the exact check
#     requested, and the one a naive filename-based check couldn't do,
#     since this script never renames anything ---------------------------
out=$("$SCRIPT" "$WORK" 2>&1)
assert_contains "$out" "already hevc" "a second run recognizes the file is already re-encoded"
assert_contains "$out" "0 re-encoded, 1 already" "a second run re-encodes nothing"

test_summary_and_exit

#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_segment_naming.sh - acceptance criterion 13: two service restarts
# within the same wall-clock hour produce two distinct archive segment
# files (FR10's per-start, not per-hour, strftime naming) - the first is
# not silently overwritten by the second. Exercises the actual segment
# muxer options nestcam-stream.sh constructs (segment_format=mpegts,
# strftime=1, segment_atclocktime=1, reset_timestamps=1), with a
# lavfi source standing in for the real v4l2 camera.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_segment_naming.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_segment_muxer() {
    # Mirrors the segment leg of nestcam-stream.sh's tee spec (Appendix A +
    # the segment_atclocktime addition), minus the tee/RTMPS half - this is
    # specifically testing FR10's naming/non-overwrite behavior, not the
    # tee isolation (that's test_tee_onfail.sh).
    timeout 3 ffmpeg -v error -f lavfi -i "testsrc=size=160x120:rate=5" -map 0:v \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10 \
        -f segment -segment_time 3600 -segment_atclocktime 1 -segment_format mpegts \
        -strftime 1 -reset_timestamps 1 \
        "$WORK/%Y%m%d_%H%M%S.ts" </dev/null >/dev/null 2>&1
}

# "Service restart" #1
run_segment_muxer
mapfile -t files_after_first < <(find "$WORK" -maxdepth 1 -name '*.ts' | sort)
assert_eq "1" "${#files_after_first[@]}" "first run produces exactly one segment file"
first_file="${files_after_first[0]:-}"
assert_file_exists "$first_file" "first segment file exists"
first_size=$(stat -c '%s' -- "$first_file" 2>/dev/null || echo 0)
assert_true "first segment file is non-empty (got ${first_size} bytes)" bash -c "[ '$first_size' -gt 0 ]"

# Real restarts are always seconds-to-minutes apart (watchdog check
# interval >=30s, rotation gap >=100s); 1.1s here only needs to clear the
# strftime naming's own one-second resolution, not simulate realistic
# restart timing.
sleep 1.1

# "Service restart" #2 - same output pattern, same directory
run_segment_muxer
mapfile -t files_after_second < <(find "$WORK" -maxdepth 1 -name '*.ts' | sort)
assert_eq "2" "${#files_after_second[@]}" "second run adds a second, distinct segment file (not an overwrite)"

assert_file_exists "$first_file" "the FIRST run's file still exists after the second run started"
first_size_after=$(stat -c '%s' -- "$first_file" 2>/dev/null || echo 0)
assert_eq "$first_size" "$first_size_after" "the first file's content is untouched by the second run (same byte size)"

if (( ${#files_after_second[@]} == 2 )); then
    second_file="${files_after_second[1]}"
    [[ "$second_file" == "$first_file" ]] && second_file="${files_after_second[0]}"
    assert_true "the two filenames are different" bash -c "[ '${files_after_second[0]}' != '${files_after_second[1]}' ]"
fi

test_summary_and_exit

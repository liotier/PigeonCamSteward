#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_archive_trim.sh - acceptance criterion 6: the archive-trim job
# retains only the configured daytime window at the configured per-hour
# duration, discarding nighttime segments entirely (or, with
# nighttime_discard: false, trimming them to the same per-hour budget
# instead). Also exercises FR11's "an hour may contain several segment
# files" grouping (criterion 13's other half - segment_naming tests the
# *production* of distinct files; this tests that the trim job correctly
# treats them as one hour's worth). Also C1: a single run sweeps every
# closed hour with files present, not just the one that closed most
# recently, while still never touching the current (potentially
# still-open) hour.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_archive_trim.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SEGMENT_DIR="$WORK/archive"
RUN_DIR="$WORK/run"
mkdir -p "$SEGMENT_DIR" "$RUN_DIR"
KEY_FILE="$WORK/stream_key"
echo "dummy-key" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

CONFIG="$WORK/config.yaml"

# "1 hour ago" is just A closed hour, not the only one archive-trim will
# look at (see C1) - scenarios 1-4 below each clear $SEGMENT_DIR before
# placing their own segment(s), so reusing this single prefix across them
# is still correct: each invocation only ever sees the one hour it just
# placed files for, regardless of which other hours a sweep would also be
# willing to process.
DAY_PREFIX=$(date -d '1 hour ago' '+%Y%m%d_%H')
NIGHT_PREFIX="$DAY_PREFIX"

mk_segment() { # mk_segment <path> <duration_seconds>
    ffmpeg -y -v error -f lavfi -i "testsrc=size=160x120:rate=5" -t "$2" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -f mpegts "$1" </dev/null
}

probe_dur() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$1" | cut -d. -f1
}

# --- scenario 1: daytime hour, three segments (simulating two restarts),
#     10 minutes each = 30 minutes total; keep 20 minutes -----------------
write_test_config "$CONFIG" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i \
    -e 's/daytime_start: "04:00"/daytime_start: "00:00"/' \
    -e 's/daytime_end: "20:30"/daytime_end: "23:59"/' \
    -e 's/daytime_keep_minutes: 60/daytime_keep_minutes: 20/' \
    "$CONFIG"

f1="$SEGMENT_DIR/${DAY_PREFIX}0000.ts"
f2="$SEGMENT_DIR/${DAY_PREFIX}1005.ts"
f3="$SEGMENT_DIR/${DAY_PREFIX}2010.ts"
mk_segment "$f1" 600
mk_segment "$f2" 600
mk_segment "$f3" 600

PIGEONCAM_CONFIG="$CONFIG" "$REPO_ROOT/bin/pigeoncam-archive-trim.sh"

assert_file_exists "$f1" "daytime: first (oldest) segment survives whole"
assert_file_exists "$f2" "daytime: second segment survives whole"
assert_file_not_exists "$f3" "daytime: third segment fully deleted once budget is exhausted"
d1=$(probe_dur "$f1"); d2=$(probe_dur "$f2")
assert_ge "$d1" 590 "first segment duration ~unchanged (was 600s, budget covered it)"
assert_ge "$d2" 590 "second segment duration ~unchanged (was 600s, budget covered it)"

# --- scenario 2: same hour, but keep only 5 minutes -> first segment
#     should be TRIMMED (partial keep), not just kept-or-deleted whole -----
rm -f "$SEGMENT_DIR"/*
sed -i 's/daytime_keep_minutes: 20/daytime_keep_minutes: 5/' "$CONFIG"
g1="$SEGMENT_DIR/${DAY_PREFIX}0000.ts"
mk_segment "$g1" 600
PIGEONCAM_CONFIG="$CONFIG" "$REPO_ROOT/bin/pigeoncam-archive-trim.sh"
assert_file_exists "$g1" "single 10-minute segment, 5-minute budget: file still exists (trimmed, not deleted)"
gd=$(probe_dur "$g1")
assert_true "trimmed segment duration is close to the 300s budget (got ${gd}s)" \
    bash -c "[ '$gd' -ge 290 ] && [ '$gd' -le 320 ]"

# --- scenario 3: nighttime hour -> segments discarded entirely -----------
rm -f "$SEGMENT_DIR"/*
sed -i \
    -e 's/daytime_start: "00:00"/daytime_start: "23:59"/' \
    -e 's/daytime_end: "23:59"/daytime_end: "23:59"/' \
    "$CONFIG"
n1="$SEGMENT_DIR/${NIGHT_PREFIX}0000.ts"
n2="$SEGMENT_DIR/${NIGHT_PREFIX}1500.ts"
mk_segment "$n1" 120
mk_segment "$n2" 120
PIGEONCAM_CONFIG="$CONFIG" "$REPO_ROOT/bin/pigeoncam-archive-trim.sh"
assert_file_not_exists "$n1" "nighttime: first segment discarded entirely"
assert_file_not_exists "$n2" "nighttime: second segment discarded entirely"

# --- scenario 4: same nighttime window, but nighttime_discard: false ->
#     trimmed to daytime_keep_minutes instead of discarded outright (still
#     the 5-minute/300s budget set in scenario 2, never reset since) -------
rm -f "$SEGMENT_DIR"/*
sed -i 's/nighttime_discard: true/nighttime_discard: false/' "$CONFIG"
p1="$SEGMENT_DIR/${NIGHT_PREFIX}0000.ts"
mk_segment "$p1" 600
PIGEONCAM_CONFIG="$CONFIG" "$REPO_ROOT/bin/pigeoncam-archive-trim.sh"
assert_file_exists "$p1" "nighttime with nighttime_discard: false: segment survives (trimmed, not deleted)"
pd=$(probe_dur "$p1")
assert_true "nighttime_discard: false trims to the daytime_keep_minutes budget (got ${pd}s)" \
    bash -c "[ '$pd' -ge 290 ] && [ '$pd' -le 320 ]"

# --- scenario 5: C1 - a single run sweeps every closed hour with files
#     present, not just the one that closed most recently: two different
#     older hours (2h ago, 5h ago) both get trimmed to the same per-hour
#     budget in one invocation, while the current (potentially still-open)
#     hour is left completely untouched ------------------------------------
rm -f "$SEGMENT_DIR"/*
sed -i \
    -e 's/daytime_start: "23:59"/daytime_start: "00:00"/' \
    -e 's/daytime_end: "23:59"/daytime_end: "23:59"/' \
    "$CONFIG"
TWO_HOURS_AGO_PREFIX=$(date -d '2 hours ago' '+%Y%m%d_%H')
FIVE_HOURS_AGO_PREFIX=$(date -d '5 hours ago' '+%Y%m%d_%H')
CURRENT_HOUR_PREFIX=$(date '+%Y%m%d_%H')

older1="$SEGMENT_DIR/${TWO_HOURS_AGO_PREFIX}0000.ts"
older2="$SEGMENT_DIR/${FIVE_HOURS_AGO_PREFIX}0000.ts"
current="$SEGMENT_DIR/${CURRENT_HOUR_PREFIX}0000.ts"
mk_segment "$older1" 600
mk_segment "$older2" 600
mk_segment "$current" 600

PIGEONCAM_CONFIG="$CONFIG" "$REPO_ROOT/bin/pigeoncam-archive-trim.sh"

od1=$(probe_dur "$older1")
assert_true "sweep: an older closed hour (2h ago) is trimmed to the 300s budget (got ${od1}s)" \
    bash -c "[ '$od1' -ge 290 ] && [ '$od1' -le 320 ]"
od2=$(probe_dur "$older2")
assert_true "sweep: a second, even older closed hour (5h ago) is ALSO trimmed in the same run (got ${od2}s)" \
    bash -c "[ '$od2' -ge 290 ] && [ '$od2' -le 320 ]"
cd1=$(probe_dur "$current")
assert_true "sweep: the current (potentially still-open) hour is left completely untouched (got ${cd1}s, was 600s)" \
    bash -c "[ '$cd1' -ge 590 ]"

test_summary_and_exit

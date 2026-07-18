#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_tee_onfail.sh - acceptance criterion 12: with archiving enabled,
# making segment_dir unwritable does not interrupt the RTMPS push - the
# live leg continues, the archive leg's failure is isolated (FR9's
# asymmetric onfail=ignore/onfail=abort + use_fifo=1). Also confirms the
# converse: a failure on the *primary* leg still aborts the whole process
# (so systemd's Restart=always actually engages), proving the asymmetry
# runs the right direction and isn't just "always survive".
#
# Uses local files as stand-ins for the real RTMPS destination - this is
# exercising ffmpeg's own tee/fifo muxer semantics against the exact
# options nestcam-stream.sh constructs, not the network.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_tee_onfail.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- scenario 1: archive leg fails (target dir doesn't exist), onfail=ignore ---
mkdir -p "$WORK/s1"
primary="$WORK/s1/primary.flv"
archive_bad="$WORK/s1/does_not_exist/archive.ts"

ffmpeg -v error -f lavfi -i "testsrc=size=160x120:rate=5" -t 2 -map 0:v \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10 \
    -f tee -use_fifo 1 \
    "[f=flv:onfail=abort]${primary}|[f=mpegts:onfail=ignore]${archive_bad}" \
    -y </dev/null >"$WORK/s1.out" 2>"$WORK/s1.err"
rc=$?

assert_eq "0" "$rc" "process exits 0 when only the (onfail=ignore) archive leg fails"
assert_file_exists "$primary" "primary/live output was written despite the archive leg failing"
psize=$(stat -c '%s' -- "$primary" 2>/dev/null || echo 0)
assert_true "primary output is non-empty (got ${psize} bytes)" bash -c "[ '$psize' -gt 0 ]"
assert_file_not_exists "$archive_bad" "the archive leg genuinely never wrote anything (its directory really doesn't exist)"

# --- scenario 2: primary leg fails, archive leg succeeds; onfail=abort
#     (the default) on the primary must still take the whole process down,
#     so systemd's Restart=always actually engages on a dead network push ---
mkdir -p "$WORK/s2"
primary_bad="$WORK/s2/does_not_exist/primary.flv"
archive_ok="$WORK/s2/archive.ts"

ffmpeg -v error -f lavfi -i "testsrc=size=160x120:rate=5" -t 2 -map 0:v \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10 \
    -f tee -use_fifo 1 \
    "[f=flv:onfail=abort]${primary_bad}|[f=mpegts:onfail=ignore]${archive_ok}" \
    -y </dev/null >"$WORK/s2.out" 2>"$WORK/s2.err"
rc=$?

assert_true "process exits non-zero when the (onfail=abort) primary leg fails (got rc=$rc)" bash -c "[ '$rc' -ne 0 ]"

# --- scenario 3: sanity baseline - both legs writable, both succeed -------
mkdir -p "$WORK/s3"
primary_ok="$WORK/s3/primary.flv"
archive_ok3="$WORK/s3/archive.ts"

ffmpeg -v error -f lavfi -i "testsrc=size=160x120:rate=5" -t 2 -map 0:v \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10 \
    -f tee -use_fifo 1 \
    "[f=flv:onfail=abort]${primary_ok}|[f=mpegts:onfail=ignore]${archive_ok3}" \
    -y </dev/null >"$WORK/s3.out" 2>"$WORK/s3.err"
rc=$?

assert_eq "0" "$rc" "baseline: process exits 0 when both legs succeed"
assert_file_exists "$primary_ok" "baseline: primary output written"
assert_file_exists "$archive_ok3" "baseline: archive output written"

test_summary_and_exit

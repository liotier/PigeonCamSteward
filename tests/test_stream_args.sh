#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_stream_args.sh - C5: pigeoncam-stream.sh threads camera.thread_queue_size
# and audio.bitrate_kbps into the real ffmpeg command line it builds, not
# just the historically-hardcoded 512/128k from SPEC.md Appendix A's
# reference shape - those numbers are still the shipped defaults, but a
# user previously had no way to override either value through config.yaml
# at all. Drives the real script via a fake ffmpeg that logs its full argv
# and exits immediately, rather than re-implementing any part of the
# command by hand (no other test in this suite invokes pigeoncam-stream.sh
# itself for this reason - it normally execs into a real, long-running
# ffmpeg).

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_stream_args.sh ==="

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

ARGV_LOG="$WORK/ffmpeg-argv.log"

run_stream() {
    : > "$ARGV_LOG"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG" \
    FAKE_FFMPEG_ARGV_LOG="$ARGV_LOG" \
    "$REPO_ROOT/bin/pigeoncam-stream.sh"
}

# --- defaults match SPEC.md Appendix A's reference values ----------------
run_stream
argv=$(cat "$ARGV_LOG")
assert_contains "$argv" "-thread_queue_size 512" "default camera.thread_queue_size (512) matches Appendix A"
assert_contains "$argv" "-b:a 128k" "default audio.bitrate_kbps (128) matches Appendix A"
assert_contains "$argv" "-nostats" "the interactive \r-redrawn stats line is suppressed (journald 'blob data')"

# --- both are actually configurable, not just documented defaults --------
sed -i \
    -e '/^camera:/a\  thread_queue_size: 1024' \
    -e '/^audio:/a\  bitrate_kbps: 96' \
    "$CONFIG"
run_stream
argv2=$(cat "$ARGV_LOG")
assert_contains "$argv2" "-thread_queue_size 1024" "camera.thread_queue_size is actually configurable"
assert_contains "$argv2" "-b:a 96k" "audio.bitrate_kbps is actually configurable"
assert_not_contains "$argv2" "-thread_queue_size 512" "the old hardcoded 512 no longer appears once overridden"
assert_not_contains "$argv2" "-b:a 128k" "the old hardcoded 128k no longer appears once overridden"

test_summary_and_exit

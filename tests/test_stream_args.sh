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
assert_contains "$argv" "-y" "never wait on ffmpeg's overwrite confirmation - no TTY under systemd to answer it (2026-08-02 outage)"
assert_not_contains "$argv" "-f image2" "watchdog.frame_freeze disabled by default: no snapshot output added to argv"

# --- watchdog.frame_freeze.enabled adds a second, gated snapshot output --
# (watchdog.frame_freeze.enabled: false is the first "enabled: false" line
# in the generated config - write_test_config's external_check.frame_freeze
# block also has one, further down, which the "0," start (match the first
# occurrence in the whole file, a GNU sed extension) deliberately leaves
# alone; a plain /pattern/,/pattern/ range would re-open on that second
# block too, since both blocks share the same "frame_freeze:" opener.)
sed -i '0,/^    enabled: false/ s/^    enabled: false/    enabled: true/' "$CONFIG"
run_stream
argv_snapshot=$(cat "$ARGV_LOG")
assert_contains "$argv_snapshot" "-f image2" "watchdog.frame_freeze.enabled=true adds the snapshot output"
assert_contains "$argv_snapshot" "-update 1" "snapshot output overwrites one file in place, not sequential numbering"
assert_contains "$argv_snapshot" "$RUN_DIR/last_frame.jpg" "snapshot output targets the configured snapshot_path"
assert_contains "$argv_snapshot" "scale=480" "snapshot is downscaled, not full-resolution (2026-08-02 audio-hiccup outage)"

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

# --- real-ffmpeg regression: the snapshot output must survive a target
#     file that already exists (2026-08-02 production outage). The fake
#     ffmpeg above only ever logs argv and exits - it never actually opens
#     a real output file, so it cannot catch ffmpeg's own overwrite-prompt
#     behavior. This drives real ffmpeg against the exact fragment
#     pigeoncam-stream.sh emits for the snapshot output (verified present
#     in argv2 above), standing a synthetic lavfi source in for the real
#     v4l2 camera - the v4l2 input itself isn't exercisable without real
#     hardware, but the failure was never about the input, it was the
#     image2 muxer refusing to overwrite an already-existing file without
#     -y. Same "skip if ffmpeg isn't available" fallback as
#     tests/test_offline_reencode.sh. -------------------------------------
if command -v ffmpeg >/dev/null 2>&1; then
    SNAPSHOT_REPRO="$WORK/last_frame.jpg"
    run_real_snapshot_ffmpeg() {
        timeout 10 ffmpeg -v error -y -f lavfi -i "testsrc=size=1920x1080:rate=1" \
            -map 0:v -vf "fps=1/60,scale=480:-2" -update 1 -f image2 "$SNAPSHOT_REPRO" \
            </dev/null >/dev/null 2>&1
    }
    run_real_snapshot_ffmpeg
    assert_true "real ffmpeg: first snapshot write succeeds (target didn't exist yet)" \
        bash -c "[ -s '$SNAPSHOT_REPRO' ]"

    # Backdate before the second run so success is unambiguous from mtime
    # alone: a silently-refused second write (no -y) would leave this
    # backdated mtime untouched, which a plain "[ -s file ]" check can't
    # tell apart from a genuine fresh overwrite - exactly the gap that let
    # this assertion pass even with -y removed from this repro function,
    # caught while verifying this test actually fails without the fix.
    touch -d '1 hour ago' "$SNAPSHOT_REPRO"
    run_real_snapshot_ffmpeg
    snapshot_age=$(( $(date +%s) - $(stat -c '%Y' -- "$SNAPSHOT_REPRO") ))
    assert_true "real ffmpeg: second write (target already exists) actually refreshes the file with -y - without it, this exact case took production down on 2026-08-02" \
        bash -c "(( $snapshot_age < 30 ))"

    if command -v ffprobe >/dev/null 2>&1; then
        snapshot_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
            -of csv=p=0 "$SNAPSHOT_REPRO" 2>/dev/null)
        assert_eq "480" "$snapshot_width" \
            "real ffmpeg: snapshot is actually downscaled (not just argv text) - a full-res encode once/minute measurably starved the audio pipeline, surfacing as Non-monotonic DTS bursts exactly on the 60s boundary in production on 2026-08-02"
    fi
else
    echo "  SKIP - real ffmpeg not available in this environment (real-ffmpeg snapshot-overwrite regression)"
fi

test_summary_and_exit

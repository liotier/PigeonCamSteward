#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_progress_last_frame.sh - regression test for a real production
# incident: progress_last_frame() piped `tac | grep -m1 | cut`, which
# reliably SIGPIPEs `tac` once the progress file is large enough that
# `tac` is still writing the rest of the reversed file after `grep -m1`
# has already found its match (near the start of tac's reversed output)
# and exited. Under this project's pipefail, that made the whole
# pipeline "fail" even though it printed the right value - and since
# bin/pigeoncam-watchdog.sh assigns the result via a bare
# `cur_frame=$(progress_last_frame ...)`, set -e then silently killed
# the entire watchdog invocation before it logged anything at all.
#
# Confirmed against real production logs: ~98% of watchdog runs were
# dying this way, every time the progress file grew past a trivial size
# (i.e. almost the entire time a stream had been running for more than a
# minute or two) - completely silently, with zero diagnostic output,
# which is exactly what made it invisible until real logs were reviewed
# directly rather than caught by this suite's existing tests (all of
# which use tiny, few-line progress fixtures where the race can't occur).

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/pigeoncam-common.sh
source "$REPO_ROOT/lib/pigeoncam-common.sh"

echo "=== test_progress_last_frame.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- small file: the case every other test in this suite already
#     exercises indirectly - confirmed still correct after the fix ------
SMALL="$WORK/progress-small"
printf 'frame=10\nprogress=continue\n' > "$SMALL"
assert_eq "10" "$(progress_last_frame "$SMALL")" "small progress file: correct frame value"

# --- large file: reproduces the real production incident. -progress
#     writes one ~11-line block per second and the file is never
#     truncated within a run, so any stream that's been up more than a
#     few minutes produces a progress file at least this size. Built
#     with awk, not a bash loop, so generating it doesn't dominate this
#     test's runtime. -------------------------------------------------
LARGE="$WORK/progress-large"
awk 'BEGIN {
    for (i = 1; i <= 20000; i++) {
        printf "frame=%d\nfps=30.00\nstream_0_0_q=23.0\nbitrate=6000.0kbits/s\ntotal_size=123456789\nout_time_us=%d\nout_time=00:00:00.000000\ndup_frames=0\ndrop_frames=0\nspeed=1.0x\nprogress=continue\n", i, i*33333
    }
}' > "$LARGE"

result=$(progress_last_frame "$LARGE"); rc=$?
assert_eq "0" "$rc" "large progress file: progress_last_frame itself exits 0 (no SIGPIPE-under-pipefail failure)"
assert_eq "20000" "$result" "large progress file: still returns the correct (most recent) frame value"

# --- the exact watchdog.sh integration pattern - a bare command
#     substitution assignment under set -e, which is what actually let
#     the underlying pipefail failure kill the entire script in
#     production, silently, before it ever logged anything ---------------
WRAPPER="$WORK/wrapper.sh"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
echo "before"
cur_frame=\$(progress_last_frame "$LARGE")
echo "after cur_frame=\$cur_frame"
EOF
chmod +x "$WRAPPER"
wrapper_out=$("$WRAPPER" 2>&1); wrapper_rc=$?
assert_eq "0" "$wrapper_rc" "watchdog-style bare assignment under set -e: the calling script survives"
assert_contains "$wrapper_out" "after cur_frame=20000" "watchdog-style bare assignment: reaches the line after the call with the right value"

# --- SECOND production incident (2026-08-02), same function, same fatal
#     bare-assignment pattern, different upstream cause - and NOT covered
#     by any assertion above, all of which use fixtures that do contain a
#     frame= line. pigeoncam-stream.sh truncates the progress file on every
#     start, so for the first moments of every single stream restart the
#     file exists but has no frame= line yet. grep then exits 1, pipefail
#     propagates it, and set -e killed the watchdog outright - silently,
#     again. Observed in production as `pigeoncam-watchdog.service: Main
#     process exited, code=exited, status=1/FAILURE` with zero log lines,
#     leaving the watchdog blind for ~30s after each restart, i.e. exactly
#     when a just-restarted stream is least stable. ----------------------
NOFRAME="$WORK/progress-no-frame-yet"
printf 'bitrate=N/A\nout_time=00:00:00.000000\nprogress=continue\n' > "$NOFRAME"

noframe_result=$(progress_last_frame "$NOFRAME"); noframe_rc=$?
assert_eq "0" "$noframe_rc" "progress file with no frame= line yet: the function itself still exits 0"
assert_eq "" "$noframe_result" "progress file with no frame= line yet: returns empty, per its documented contract"

# An entirely empty progress file - the very first instant after
# pigeoncam-stream.sh's `: > "$progress_file"` truncation, before ffmpeg
# has written anything at all.
EMPTY="$WORK/progress-empty"
: > "$EMPTY"
empty_result=$(progress_last_frame "$EMPTY"); empty_rc=$?
assert_eq "0" "$empty_rc" "completely empty progress file (just truncated): the function still exits 0"
assert_eq "" "$empty_result" "completely empty progress file: returns empty rather than failing"

# The integration pattern that actually did the damage, for the no-frame
# fixture: a bare command substitution under set -e in the caller.
NOFRAME_WRAPPER="$WORK/wrapper-noframe.sh"
cat > "$NOFRAME_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
echo "before"
cur_frame=\$(progress_last_frame "$NOFRAME")
echo "after cur_frame=[\$cur_frame]"
EOF
chmod +x "$NOFRAME_WRAPPER"
nf_out=$("$NOFRAME_WRAPPER" 2>&1); nf_rc=$?
assert_eq "0" "$nf_rc" "no-frame-yet + watchdog-style bare assignment under set -e: the calling script survives"
assert_contains "$nf_out" "after cur_frame=[]" "no-frame-yet: caller reaches the line after the call, with an empty value"

# --- and the real watchdog binary itself, end to end: a freshly-truncated
#     progress file must not kill it. Uses the real script with a fake
#     systemctl, exactly like tests/test_watchdog.sh. --------------------
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"
WD_RUN="$WORK/wd-run"; WD_SEG="$WORK/wd-seg"
mkdir -p "$WD_RUN" "$WD_SEG"
WD_KEY="$WORK/wd-key"; echo dummy > "$WD_KEY"; chmod 600 "$WD_KEY"
WD_CONFIG="$WORK/wd-config.yaml"
write_test_config "$WD_CONFIG" "$WD_RUN" "$WD_SEG" "$WD_KEY"
printf 'bitrate=N/A\nprogress=continue\n' > "$WD_RUN/progress"

: > "$WORK/wd-systemctl.log"
PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$WD_CONFIG" \
    FAKE_SYSTEMCTL_LOG="$WORK/wd-systemctl.log" FAKE_SYSTEMCTL_ACTIVE=active \
    "$REPO_ROOT/bin/pigeoncam-watchdog.sh" >/dev/null 2>&1; wd_rc=$?
assert_eq "0" "$wd_rc" "real watchdog against a freshly-truncated progress file: exits 0, not 1/FAILURE"

# It must also complete its normal bookkeeping rather than bailing early:
# a fresh progress file is healthy (not stalled), so no restart is due, and
# the state file must have been written. Before the fix the script died
# before reaching either - the state file is the durable proof it ran to
# completion, since the healthy path deliberately logs nothing (a watchdog
# that printed a line every 30s would be pure journal spam).
assert_eq "0" "$(grep -c 'restart pigeoncam-stream.service' "$WORK/wd-systemctl.log" 2>/dev/null; true)" \
    "real watchdog, freshly-truncated progress file: healthy, so no restart issued"
assert_true "real watchdog, freshly-truncated progress file: ran to completion (state file written)" \
    bash -c "[ -f '$WD_RUN/watchdog.state' ]"

test_summary_and_exit

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

test_summary_and_exit

#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_err_trap.sh - item 2 of the 2026-08-02 architecture review: three
# separate production incidents (see docs/TROUBLESHOOTING.md's two "no log
# output at all" entries) shared one shape - a bare `x=$(pipeline)`
# assignment failing under `set -euo pipefail`, silently killing the whole
# script before it logged anything. lib/pigeoncam-common.sh now installs
# an ERR trap (with `set -o errtrace`, without which it would not fire
# inside functions - exactly where all three incidents happened) so any
# FUTURE unguarded failure logs a diagnostic before set -e exits, instead
# of exiting silently. This drives real throwaway scripts against the
# real lib rather than asserting on the lib's source text, since the
# whole point is behavior under set -e/errtrace, not what the code says.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_err_trap.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- an unguarded failure inside a function must log file:line and the
#     failing command, then still exit non-zero (the trap does not change
#     control flow - it only guarantees a diagnostic first) --------------
UNGUARDED="$WORK/unguarded.sh"
cat > "$UNGUARDED" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
PIGEONCAM_LOG_TAG=test

do_the_failing_thing() {
    grep '^frame=' /this/path/does/not/exist   # line 7
}

echo "before"
do_the_failing_thing
echo "after (must NOT print - set -e still exits)"
EOF
chmod +x "$UNGUARDED"
out=$("$UNGUARDED" 2>&1); rc=$?
# grep's own exit code (2, "file not found"/error) propagates through -
# set -e exits with whatever the failing command itself returned, not a
# fixed code; the trap only adds a diagnostic, never changes this.
assert_eq "2" "$rc" "unguarded failure inside a function: script exits with the failing command's own code"
assert_contains "$out" "before" "unguarded failure: reaches the line before the failing call"
assert_not_contains "$out" "after (must NOT print" "unguarded failure: set -e still exits - does not continue past it"
assert_contains "$out" "unhandled failure at" "unguarded failure: the trap logs a diagnostic"
assert_contains "$out" "unguarded.sh:7" "unguarded failure: diagnostic names the CALLING script's failing line, not the lib's (BASH_SOURCE[1]/BASH_LINENO[0], verified empirically before landing this)"
assert_contains "$out" "grep '^frame=' /this/path/does/not/exist" "unguarded failure: diagnostic names the actual failing command"

# --- a `|| return 0`-guarded failure - this project's own standing
#     idiom for "this can legitimately produce nothing" - must NOT trip
#     the trap. This is the regression that matters most: the trap must
#     never turn every intentional guard already in this codebase into
#     log spam. ------------------------------------------------------
GUARDED_OR="$WORK/guarded_or.sh"
cat > "$GUARDED_OR" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
PIGEONCAM_LOG_TAG=test

guarded() {
    local x
    x=\$(grep '^frame=' /this/path/does/not/exist 2>/dev/null) || return 0
    printf '%s' "\$x"
}

echo "before"
guarded
echo "after (SHOULD print - the guard handled it, this is not a bug)"
EOF
chmod +x "$GUARDED_OR"
out=$("$GUARDED_OR" 2>&1); rc=$?
assert_eq "0" "$rc" "|| return 0-guarded failure: script exits 0 normally"
assert_contains "$out" "after (SHOULD print" "|| return 0-guarded failure: execution continues past it"
assert_not_contains "$out" "unhandled failure at" "|| return 0-guarded failure: does NOT trip the trap - this is handled failure, not a bug"

# --- an `if ! cmd; then ... fi`-guarded failure - the other standing
#     idiom used throughout pigeoncam-doctor.sh - must also stay silent -
GUARDED_IF="$WORK/guarded_if.sh"
cat > "$GUARDED_IF" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
PIGEONCAM_LOG_TAG=test

if ! grep -q nope /this/path/does/not/exist 2>/dev/null; then
    echo "if-guarded failure handled normally"
fi
echo "after"
EOF
chmod +x "$GUARDED_IF"
out=$("$GUARDED_IF" 2>&1); rc=$?
assert_eq "0" "$rc" "if !-guarded failure: script exits 0 normally"
assert_contains "$out" "if-guarded failure handled normally" "if !-guarded failure: the intended branch runs"
assert_not_contains "$out" "unhandled failure at" "if !-guarded failure: does NOT trip the trap"

# --- the exact historical shape, re-verified: progress_last_frame's own
#     documented "no frame yet" contract (empty, exit 0) must not trip
#     the trap either, now that the function guards its own internal
#     failure with `|| return 0` -----------------------------------------
NOFRAME="$WORK/progress-noframe"
printf 'bitrate=N/A\nprogress=continue\n' > "$NOFRAME"
HIST="$WORK/historical.sh"
cat > "$HIST" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
PIGEONCAM_LOG_TAG=test
cur_frame=\$(progress_last_frame "$NOFRAME") || cur_frame=""
echo "cur_frame=[\$cur_frame]"
EOF
chmod +x "$HIST"
out=$("$HIST" 2>&1); rc=$?
assert_eq "0" "$rc" "historical no-frame-yet case: script exits 0"
assert_contains "$out" "cur_frame=[]" "historical no-frame-yet case: empty value reaches the caller"
assert_not_contains "$out" "unhandled failure at" "historical no-frame-yet case: does NOT trip the new trap"

# --- `main "$@" || exit $?` is BANNED, and this is why -----------------
#
# It looks like the obvious way to stop a script's deliberate non-zero
# exit (doctor.sh's "some checks FAILed", ctl.sh status's "a unit is
# down") from tripping this trap. It is a trap of its own: putting main
# in a condition context disables `set -e` for main *and everything it
# calls, recursively*, and suppresses this trap along with it.
#
# Measured, not assumed - a set -euo pipefail script whose dispatch line
# was `main "$@" || exit $?` ran straight past a failing command inside a
# nested function, printed the line after it, and exited 0. On any of the
# watchdog/status-check/rotate/stream scripts that would silently undo
# both set -e and item 2a in a single line, and leave exactly the
# "reports healthy while blind" behaviour this project exists to prevent.
#
# The correct way, used by both scripts that need it: have main() call
# `exit N` explicitly. A plain exit does not trip the trap, and real
# failures deeper inside still do (both verified directly).
#
# Structural check - the behavioural ones live in test_doctor.sh and
# test_ctl.sh, which run the real scripts and assert no spurious
# "this is a bug" reaches the operator.
shopt -s nullglob
for script in "$REPO_ROOT"/bin/*.sh; do
    name=$(basename "$script")
    # ^[^#]* so the comments in doctor.sh/ctl.sh that *describe* the banned
    # pattern (and must keep quoting it, to be readable) don't match it.
    banned=$(grep -nE '^[^#]*main "\$@"[[:space:]]*\|\|' "$script" || true)
    assert_eq "" "$banned" \
        "$name does not use the banned 'main \"\$@\" || ...' dispatch (it would disable set -e inside main and everything it calls)"
done
shopt -u nullglob

# --- and the reason that ban is safe: a script whose main() exits
#     explicitly still gets full set -e + trap coverage for real bugs ---
EXPLICIT="$WORK/explicit-exit.sh"
cat > "$EXPLICIT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/lib/pigeoncam-common.sh"
PIGEONCAM_LOG_TAG=test
inner() { false; echo "CONTINUED PAST FAILURE"; }
main() { inner; }
main "\$@"
EOF
chmod +x "$EXPLICIT"
out=$("$EXPLICIT" 2>&1); rc=$?
assert_eq "1" "$rc" "explicit-exit dispatch style: a real deep failure still aborts with the failing command's code"
assert_not_contains "$out" "CONTINUED PAST FAILURE" "explicit-exit dispatch style: set -e still bites inside nested functions"
assert_contains "$out" "unhandled failure at" "explicit-exit dispatch style: the trap still reports real bugs"

test_summary_and_exit

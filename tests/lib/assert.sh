# shellcheck shell=bash
# SPDX-License-Identifier: Unlicense
#
# tests/lib/assert.sh - tiny assertion helpers for the PigeonCamSteward test
# suite. No external test framework dependency (bats is not part of the
# project's dependency table) - sourced by each tests/test_*.sh file.

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    # Default messages reference $1/$2 (positional params), not the
    # same-named locals below: within one `local a=$1 b=$a` statement, RHS
    # expansions all resolve against the pre-statement environment, so a
    # later default value can't see an earlier local from the same
    # statement (confirmed empirically - shellcheck SC2318).
    local msg="${3:-expected '$1'}"
    local expected="$1" actual="$2"
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok - $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $msg : expected '$expected', got '$actual'"
    fi
}

assert_true() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN+1))
    if "$@"; then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc (expected success, command: $*)"
    fi
}

assert_false() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN+1))
    if ! "$@"; then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc (expected failure, command succeeded: $*)"
    fi
}

assert_file_exists() {
    local f="$1" desc="${2:-$1 exists}"
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ -e "$f" ]]; then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc (not found: $f)"
    fi
}

assert_file_not_exists() {
    local f="$1" desc="${2:-$1 does not exist}"
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ ! -e "$f" ]]; then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc (unexpectedly exists: $f)"
    fi
}

assert_contains() {
    local desc="${3:-output contains '$2'}"
    local haystack="$1" needle="$2"
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc"
        echo "    --- haystack was ---"
        echo "$haystack" | sed 's/^/    /'
    fi
}

assert_not_contains() {
    local desc="${3:-output does not contain '$2'}"
    local haystack="$1" needle="$2"
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc"
        echo "    --- haystack was ---"
        echo "$haystack" | sed 's/^/    /'
    fi
}

assert_ge() {
    local desc="${3:-$1 >= $2}"
    local actual="$1" min="$2"
    TESTS_RUN=$((TESTS_RUN+1))
    if (( actual >= min )); then
        echo "  ok - $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED+1))
        echo "  FAIL - $desc (actual=$actual, min=$min)"
    fi
}

test_summary_and_exit() {
    echo ""
    echo "== $(basename "$0"): ${TESTS_RUN} assertion(s), ${TESTS_FAILED} failed =="
    (( TESTS_FAILED == 0 ))
}

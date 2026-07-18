#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# tests/run_all.sh - runs every automated check in this directory and
# prints a final summary. Exits non-zero if anything failed.
#
# What this suite does and does not cover: it automates everything that is
# mechanically testable without real hardware or a real YouTube channel
# (acceptance criteria 1, 4, 6, 9, 10, 12, 13, 14, 15, plus config-schema,
# lint hygiene for shell and Python, and Tier 2's rotation logic against a
# mocked YouTube API). Criteria 2, 3, 5, 7, 8 genuinely need a real camera,
# a real systemd init, and/or a real YouTube channel and are not claimed
# as passing here; criterion 11's full scope needs a real stuck-broadcast
# state against the real API - see tests/MANUAL_VERIFICATION.md.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

SUITE_FAILED=0
declare -a results=()

run_one() {
    local script="$1" name
    name=$(basename -- "$script")
    echo ""
    echo "############################################################"
    echo "# $name"
    echo "############################################################"
    if bash "$script"; then
        results+=("PASS  $name")
    else
        results+=("FAIL  $name")
        SUITE_FAILED=1
    fi
}

run_one "$TESTS_DIR/shellcheck.sh"
run_one "$TESTS_DIR/python_lint.sh"
run_one "$TESTS_DIR/test_config_schema.sh"
run_one "$TESTS_DIR/test_doctor.sh"
run_one "$TESTS_DIR/test_archive_trim.sh"
run_one "$TESTS_DIR/test_segment_naming.sh"
run_one "$TESTS_DIR/test_tee_onfail.sh"
run_one "$TESTS_DIR/test_watchdog.sh"
run_one "$TESTS_DIR/test_status_check.sh"
run_one "$TESTS_DIR/test_rotate.sh"
run_one "$TESTS_DIR/test_tier2.sh"

echo ""
echo "############################################################"
echo "# SUMMARY"
echo "############################################################"
printf '%s\n' "${results[@]}"

if (( SUITE_FAILED == 0 )); then
    echo ""
    echo "All automated checks passed."
else
    echo ""
    echo "One or more checks FAILED - see above."
fi

exit "$SUITE_FAILED"

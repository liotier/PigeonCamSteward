#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# tests/shellcheck.sh - lints every shell script in the project. Requires
# -P lib so shellcheck can resolve the `source "$SCRIPT_DIR/../lib/..."`
# lines in bin/*.sh (their target is dynamic, so it can't resolve the path
# on its own without the search-path hint).

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT" || exit 1

echo "=== shellcheck ==="

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "SKIP - shellcheck is not installed (apt install shellcheck; dev/CI only, see SPEC.md §6a)"
    exit 0
fi

mapfile -t targets < <(find bin lib tests tools -name '*.sh' -type f | sort)
echo "checking ${#targets[@]} file(s): ${targets[*]}"

# --severity=warning: two SC2016 "info" hits are false positives (literal
# quote characters deliberately embedded in interpolated message strings
# for readable test output, not a quoting mistake) and one SC2001 "style"
# suggestion isn't worth the churn. Nothing at warning-or-above is
# suppressed.
if shellcheck -x -P lib -P tests/lib --severity=warning "${targets[@]}"; then
    echo "== shellcheck: clean =="
    exit 0
else
    echo "== shellcheck: issues found above =="
    exit 1
fi

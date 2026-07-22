#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# tests/python_lint.sh - lints api/*.py, lib/*.py, and tests/*.py. ruff
# covers logic/import/style issues; flake8 adds line-length enforcement
# (E501), which is not in ruff's default rule set without extra config.

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT" || exit 1

echo "=== python lint (ruff, flake8) ==="

mapfile -t targets < <(find api lib tests -maxdepth 1 -name '*.py' -type f | sort)
if (( ${#targets[@]} == 0 )); then
    echo "no Python files yet - nothing to lint"
    exit 0
fi
echo "checking ${#targets[@]} file(s): ${targets[*]}"

status=0

if command -v ruff >/dev/null 2>&1; then
    if ! ruff check "${targets[@]}"; then
        status=1
    fi
else
    echo "SKIP - ruff not installed"
fi

if command -v flake8 >/dev/null 2>&1; then
    if ! flake8 --max-line-length=120 "${targets[@]}"; then
        status=1
    fi
else
    echo "SKIP - flake8 not installed"
fi

if (( status == 0 )); then
    echo "== python lint: clean =="
else
    echo "== python lint: issues found above =="
fi
exit "$status"

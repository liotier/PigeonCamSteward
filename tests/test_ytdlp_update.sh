#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_ytdlp_update.sh - pigeoncam-ytdlp-update.sh: runs `yt-dlp -U`,
# logs whether a real update happened (old -> new version) or it was
# already current, and fails loudly (non-zero exit) rather than silently
# on an update error or a missing yt-dlp binary.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_ytdlp_update.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_update() {
    local update_mode="$1" state_file="$2"
    PATH="$FAKE_BIN:$PATH" \
    FAKE_YTDLP_UPDATE_MODE="$update_mode" \
    FAKE_YTDLP_STATE_FILE="$state_file" \
    FAKE_YTDLP_VERSION_BEFORE="2024.01.01" \
    FAKE_YTDLP_VERSION_AFTER="2024.06.01" \
    "$REPO_ROOT/bin/pigeoncam-ytdlp-update.sh" 2>&1
}

# --- an available update is applied and logged with old -> new version ---
out=$(run_update available "$WORK/version-available"); rc=$?
assert_eq "0" "$rc" "an available update: script exits 0"
assert_contains "$out" "yt-dlp updated: 2024.01.01 -> 2024.06.01" "an available update: logs old -> new version"

# --- already current: no update applied, logged as up to date ------------
out=$(run_update current "$WORK/version-current"); rc=$?
assert_eq "0" "$rc" "already current: script exits 0"
assert_contains "$out" "yt-dlp already up to date (2024.01.01)" "already current: logs no change happened"

# --- update failure is a hard failure, not silently swallowed ------------
out=$(run_update fails "$WORK/version-fails"); rc=$?
assert_true "a failed self-update: script exits non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "self-update failed" "a failed self-update: error message says so"

# --- missing yt-dlp binary is a hard failure, not a crash -----------------
EMPTY_BIN="$WORK/empty-bin"
mkdir -p "$EMPTY_BIN"
for c in bash cat grep sed find sort mkdir rm stat date basename dirname printf timeout; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$EMPTY_BIN/$c"
done
out=$(PATH="$EMPTY_BIN" "$REPO_ROOT/bin/pigeoncam-ytdlp-update.sh" 2>&1); rc=$?
assert_true "missing yt-dlp: script exits non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "yt-dlp" "missing yt-dlp: error message names the missing command"

test_summary_and_exit

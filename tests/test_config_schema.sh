#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_config_schema.sh - config.example.yaml parses cleanly and the keys
# every script reads via cfg() actually resolve to something.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_config_schema.sh ==="

assert_true "config.example.yaml parses as YAML/JSON via yq" \
    bash -c "yq . '$REPO_ROOT/config.example.yaml' >/dev/null"

export PIGEONCAM_CONFIG="$REPO_ROOT/config.example.yaml"
# shellcheck source=lib/pigeoncam-common.sh
source "$REPO_ROOT/lib/pigeoncam-common.sh"

declare -a required_keys=(
    .camera.device
    .camera.input_format
    .camera.resolution
    .camera.framerate
    .encode.preset
    .encode.bitrate_kbps
    .audio.mode
    .youtube.ingest_url
    .youtube.stream_key_file
    .youtube.rotation.mode
    .youtube.rotation.interval
    .youtube.rotation.min_gap_seconds
    .archive.segment_dir
    .archive.segment_format
    .archive.daytime_start
    .archive.daytime_end
    .watchdog.progress_file
    .watchdog.stall_timeout_seconds
    .watchdog.usb_reset.method
    .external_check.channel_live_url
    .external_check.poll_interval_seconds
    .external_check.max_restarts_before_escalation
)

for k in "${required_keys[@]}"; do
    v=$(cfg "$k" "")
    assert_true "config key $k resolves to a non-empty value" [ -n "$v" ]
done

# archive.enabled is a boolean that must survive as a real "true", not fall
# through cfg()'s default handling (see lib/pigeoncam-common.sh's note on the
# jq `//` operator false-vs-null gotcha).
v=$(cfg '.archive.enabled' MISSING)
assert_eq "true" "$v" "archive.enabled reads as literal 'true'"

test_summary_and_exit

#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_tier2.sh - Tier 2 (FR15): drives the real rotate_via_api.py against
# a hand-built fake YouTube service object (tests/test_tier2.py) so the
# SPEC.md SS5.4.1 step sequence, state persistence, and error handling are
# verified without any real network call, plus CLI-level error-path checks
# (missing config, missing token file, tier2.enabled: false).
#
# Provisions a throwaway venv with this project's actual
# api/requirements.txt if one isn't already cached, mirroring exactly what
# a real Tier 2 setup does (docs/TIER2.md) rather than testing against
# some other environment's Python. Cached across runs at
# $NESTCAM_TEST_VENV (default /tmp/nestcam-tier2-test-venv) - delete it to
# force a clean reinstall.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_tier2.sh ==="

VENV_CACHE="${NESTCAM_TEST_VENV:-/tmp/nestcam-tier2-test-venv}"

if [[ ! -x "$VENV_CACHE/bin/python3" ]]; then
    echo "provisioning a test venv at $VENV_CACHE from api/requirements.txt ..."
    if ! python3 -m venv "$VENV_CACHE" >/dev/null 2>&1 \
        || ! "$VENV_CACHE/bin/pip" install --quiet -r "$REPO_ROOT/api/requirements.txt" >/dev/null 2>&1; then
        echo "SKIP - could not provision a venv with Tier 2 dependencies (no network access?)"
        exit 0
    fi
fi
PYTHON="$VENV_CACHE/bin/python3"

echo "--- mocked SS5.4.1 rotation-sequence tests (Python unittest) ---"
if ( cd "$REPO_ROOT" && "$PYTHON" -m unittest tests.test_tier2 -v ); then
    echo "  ok - all mocked rotation-sequence unittest cases passed"
    TESTS_RUN=$((TESTS_RUN+1))
else
    echo "  FAIL - one or more mocked rotation-sequence unittest cases failed (see output above)"
    TESTS_RUN=$((TESTS_RUN+1))
    TESTS_FAILED=$((TESTS_FAILED+1))
fi

echo "--- CLI-level error paths ---"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CONFIG="$WORK/config.yaml"
SCRIPT="$REPO_ROOT/api/rotate_via_api.py"

cat > "$CONFIG" <<'EOF'
tier2:
  enabled: false
EOF
out=$(NESTCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" 2>&1); rc=$?
assert_true "exits non-zero when tier2.enabled is false" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "tier2.enabled is false" "error message explains why"

out=$(NESTCAM_CONFIG="$WORK/does_not_exist.yaml" "$PYTHON" "$SCRIPT" 2>&1); rc=$?
assert_true "exits non-zero when config file is missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "config file not found" "error message names the missing config"

cat > "$CONFIG" <<EOF
tier2:
  enabled: true
  token_file: $WORK/does_not_exist_token.json
  client_secret_file: $WORK/does_not_exist_secret.json
  persistent_stream_id: STREAM123
EOF
out=$(NESTCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" 2>&1); rc=$?
assert_true "exits non-zero when token_file is missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "--authorize" "error message tells the user to run --authorize"

out=$(NESTCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" --authorize 2>&1); rc=$?
assert_true "--authorize exits non-zero when client_secret_file is missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "client_secret_file" "error message names the missing client secret file"

cat > "$CONFIG" <<'EOF'
tier2:
  enabled: false
EOF
out=$(NESTCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" --recover 2>&1); rc=$?
assert_true "--recover also exits non-zero when tier2.enabled is false" bash -c "[ '$rc' -ne 0 ]"

test_summary_and_exit

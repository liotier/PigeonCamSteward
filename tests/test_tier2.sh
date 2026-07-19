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
# $PIGEONCAM_TEST_VENV (default /tmp/pigeoncam-tier2-test-venv) - delete it to
# force a clean reinstall.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_tier2.sh ==="

VENV_CACHE="${PIGEONCAM_TEST_VENV:-/tmp/pigeoncam-tier2-test-venv}"

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

# The remaining CLI-level checks want a specific, known interpreter (the
# fully-provisioned $VENV_CACHE, or a deliberately empty one below) - not
# rotate_via_api.py's own automatic re-exec into api/venv/bin/python3
# second-guessing which one actually ran. PIGEONCAM_NO_VENV_REEXEC=1
# disables that so these tests stay deterministic regardless of whether a
# real api/venv/ happens to exist on whatever host runs the suite (it
# never does in CI, but a dev machine with its own Tier 2 setup could have
# one right there in the same checkout).
NO_REEXEC=(PIGEONCAM_NO_VENV_REEXEC=1)

# Reproduces the real-world mistake of running `./rotate_via_api.py`
# directly instead of through api/venv/bin/python3: whatever interpreter
# lacks Tier 2's deps should get a clear fix, not a raw traceback. A fresh
# empty venv deterministically lacks them regardless of what's installed
# on this host's system Python.
EMPTY_VENV="$WORK/empty-venv"
if python3 -m venv "$EMPTY_VENV" >/dev/null 2>&1; then
    out=$(env "${NO_REEXEC[@]}" "$EMPTY_VENV/bin/python3" "$SCRIPT" --authorize 2>&1); rc=$?
    assert_true "no Tier 2 deps on PATH: script exits non-zero, not a crash" bash -c "[ '$rc' -ne 0 ]"
    assert_contains "$out" "no venv at api/venv/ yet" "no Tier 2 deps on PATH: error explains the venv requirement"
    assert_contains "$out" "api/venv/bin/pip install" "no Tier 2 deps on PATH: error names the fix"
else
    echo "  SKIP - could not provision an empty venv to test the missing-deps guard"
fi

# --- re-exec: invoked via a DIFFERENT interpreter, with a real venv next
# to the script, transparently hands off to that venv instead of failing
# (this is what makes the EMPTY_VENV case above the exception rather than
# the rule - normally there IS a real api/venv/ to redirect into) --------
REEXEC_DIR="$WORK/reexec-test"
mkdir -p "$REEXEC_DIR/venv/bin"
cp "$SCRIPT" "$REEXEC_DIR/rotate_via_api.py"
cat > "$REEXEC_DIR/venv/bin/python3" <<'FAKEPY'
#!/usr/bin/env bash
echo "REACHED_FAKE_VENV: $*"
FAKEPY
chmod +x "$REEXEC_DIR/venv/bin/python3"
# Deliberately NOT in NO_REEXEC's env - this is the one case that should
# actually re-exec. Plain `python3` (not the fake venv, not $VENV_CACHE)
# stands in for a caller who never heard of the venv at all.
out=$(python3 "$REEXEC_DIR/rotate_via_api.py" --list-streams 2>&1); rc=$?
assert_contains "$out" "REACHED_FAKE_VENV" "re-exec: running without the venv prefix hands off to <script-dir>/venv/bin/python3 automatically"
assert_contains "$out" "--list-streams" "re-exec: the original arguments are preserved across the hand-off"

cat > "$CONFIG" <<'EOF'
tier2:
  enabled: false
EOF
out=$(env "${NO_REEXEC[@]}" PIGEONCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" 2>&1); rc=$?
assert_true "exits non-zero when tier2.enabled is false" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "tier2.enabled is false" "error message explains why"

out=$(env "${NO_REEXEC[@]}" PIGEONCAM_CONFIG="$WORK/does_not_exist.yaml" "$PYTHON" "$SCRIPT" 2>&1); rc=$?
assert_true "exits non-zero when config file is missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "config file not found" "error message names the missing config"

cat > "$CONFIG" <<EOF
tier2:
  enabled: true
  token_file: $WORK/does_not_exist_token.json
  client_secret_file: $WORK/does_not_exist_secret.json
  persistent_stream_id: STREAM123
EOF
out=$(env "${NO_REEXEC[@]}" PIGEONCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" 2>&1); rc=$?
assert_true "exits non-zero when token_file is missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "--authorize" "error message tells the user to run --authorize"

out=$(env "${NO_REEXEC[@]}" PIGEONCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" --authorize 2>&1); rc=$?
assert_true "--authorize exits non-zero when client_secret_file is missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "client_secret_file" "error message names the missing client secret file"

cat > "$CONFIG" <<'EOF'
tier2:
  enabled: false
EOF
out=$(env "${NO_REEXEC[@]}" PIGEONCAM_CONFIG="$CONFIG" "$PYTHON" "$SCRIPT" --recover 2>&1); rc=$?
assert_true "--recover also exits non-zero when tier2.enabled is false" bash -c "[ '$rc' -ne 0 ]"

test_summary_and_exit

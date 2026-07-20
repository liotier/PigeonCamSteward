#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_doctor.sh - acceptance criterion 1: pigeoncam-doctor.sh correctly
# flags (a) a YUYV-only high-res mode lacking the requested frame rate,
# (b) a missing/incorrectly-permissioned stream key file, (c) an ffmpeg
# build without RTMPS support, (d) absence of a udev rule for the
# configured device path - and passes cleanly when none of those are true.
# Also B1: the shipped systemd units being installed and actually enabled,
# not just present with correct content (check_start_limit's own concern).

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
FAKE_BIN="$TESTS_DIR/fixtures/fake-bin"
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=tests/lib/fixtures.sh
source "$TESTS_DIR/lib/fixtures.sh"

echo "=== test_doctor.sh ==="

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SEGMENT_DIR="$WORK/archive"
RUN_DIR="$WORK/run"
mkdir -p "$SEGMENT_DIR" "$RUN_DIR" "$WORK/udev-good" "$WORK/udev-empty"
KEY_FILE="$WORK/stream_key"
echo "dummy-key" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
# Doctor legitimately checks that camera.device exists before asking
# v4l2-ctl about formats, so the "good" fixture needs a real (dummy) file
# there - /dev/pigeoncam itself doesn't exist on a machine with no camera.
# Its basename must still be "pigeoncam" to match the udev fixture rule below.
FAKE_DEVICE="$WORK/pigeoncam"
touch "$FAKE_DEVICE"

CONFIG="$WORK/config.yaml"
write_test_config "$CONFIG" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i "s#device: /dev/null#device: ${FAKE_DEVICE}#" "$CONFIG"
# no live channel configured -> external check should WARN, not fail, and
# must not actually hit the network
sed -i 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG"

echo 'SUBSYSTEM=="video4linux", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="0893", SYMLINK+="pigeoncam"' \
    > "$WORK/udev-good/99-pigeoncam.rules"

SYSTEMCTL_LOG="$WORK/systemctl.log"
: > "$SYSTEMCTL_LOG"

# run_doctor <v4l2_mode> <udev_dirs> [ffmpeg_mode] [config] [systemctl_state] --
# explicit parameters, not ambient env vars: `out=$(some_wrapper)` is itself
# just an assignment (no trailing command word), so env-var prefixes placed
# before a call written as `VAR=x out=$(run_doctor)` never actually reach the
# subprocess - bash only honors prefix-assignment exports on a line with a
# real trailing command. Passing everything as explicit args to a function
# that itself performs the real, trailing invocation sidesteps that trap.
run_doctor() {
    local v4l2_mode="$1" udev_dirs="$2" ffmpeg_mode="${3:-good}" config="${4:-$CONFIG}" systemctl_state="${5:-enabled}"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$config" \
    FAKE_V4L2_MODE="$v4l2_mode" \
    PIGEONCAM_DOCTOR_UDEV_DIRS="$udev_dirs" \
    FAKE_FFMPEG_MODE="$ffmpeg_mode" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_SYSTEMCTL_ENABLED_STATE="$systemctl_state" \
    "$REPO_ROOT/bin/pigeoncam-doctor.sh"
}

# --- baseline: everything good -> overall PASS ----------------------------
out=$(run_doctor good "$WORK/udev-good"); rc=$?
assert_eq "0" "$rc" "baseline: doctor exits 0 when everything checks out"
assert_contains "$out" "PASS  camera mode" "baseline: camera mode check passes"
assert_contains "$out" "PASS  stream key file" "baseline: stream key check passes"
assert_contains "$out" "PASS  udev rule" "baseline: udev rule check passes"
assert_contains "$out" "PASS  systemd unit (pigeoncam-stream.service)" "baseline: enabled stream unit passes"
assert_contains "$out" "PASS  systemd unit (pigeoncam-watchdog.timer)" "baseline: enabled watchdog timer passes"

# --- B1: a unit that's installed but never enabled is a clear FAIL, not a
#     silent gap - check_start_limit only validates the stream unit *file's*
#     content, this is the "did anyone actually turn it on" check ----------
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG" disabled); rc=$?
assert_true "B1: doctor exits non-zero when units are installed but disabled" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  systemd unit (pigeoncam-stream.service)" "B1: disabled stream unit is flagged FAIL"
assert_contains "$out" "enable --now pigeoncam-stream.service" "B1: failure message names the exact fix"
assert_contains "$out" "FAIL  systemd unit (pigeoncam-archive-trim.timer)" "B1: disabled archive-trim timer is flagged FAIL too"

# --- B1: units not installed yet (fresh checkout, before Quickstart step 5)
#     is a WARN, matching check_start_limit's own leniency for this case,
#     not a FAIL - nothing to fix wrong yet, just a step not reached -------
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG" not-found); rc=$?
assert_contains "$out" "WARN  systemd unit (pigeoncam-stream.service)" "B1: not-yet-installed units are flagged WARN, not FAIL"
assert_contains "$out" "not installed yet" "B1: WARN message is clear about why"

# --- (a) YUYV-only high-res mode lacking the requested frame rate --------
out=$(run_doctor yuyv_trap "$WORK/udev-good"); rc=$?
assert_true "criterion 1a: doctor exits non-zero on the YUYV/fps trap" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  camera mode" "criterion 1a: camera mode check is flagged FAIL"

# --- (b) missing stream key file ------------------------------------------
MISSING_KEY="$WORK/does_not_exist_key"
CONFIG_B="$WORK/config-b.yaml"
write_test_config "$CONFIG_B" "$RUN_DIR" "$SEGMENT_DIR" "$MISSING_KEY"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_B"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_B"); rc=$?
assert_true "criterion 1b: doctor exits non-zero on a missing key file" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  stream key file" "criterion 1b: missing key file is flagged FAIL"

# --- (b) incorrectly-permissioned stream key file -------------------------
BAD_PERM_KEY="$WORK/bad_perm_key"
echo "dummy" > "$BAD_PERM_KEY"
chmod 644 "$BAD_PERM_KEY"
CONFIG_B2="$WORK/config-b2.yaml"
write_test_config "$CONFIG_B2" "$RUN_DIR" "$SEGMENT_DIR" "$BAD_PERM_KEY"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_B2"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_B2"); rc=$?
assert_true "criterion 1b: doctor exits non-zero on a mode-644 key file" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  stream key file" "criterion 1b: wrong-permission key file is flagged FAIL"

# --- (c) ffmpeg build without RTMPS support -------------------------------
out=$(run_doctor good "$WORK/udev-good" no_rtmps); rc=$?
assert_true "criterion 1c: doctor exits non-zero when ffmpeg lacks RTMPS support" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  ffmpeg build" "criterion 1c: ffmpeg build check is flagged FAIL"
assert_contains "$out" "gnutls/openssl" "criterion 1c: failure message names the missing TLS backend"

# --- (d) absence of a udev rule for the configured device path -----------
out=$(run_doctor good "$WORK/udev-empty"); rc=$?
assert_true "criterion 1d: doctor exits non-zero when no udev rule matches" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  udev rule" "criterion 1d: udev rule check is flagged FAIL"

# --- audio.mode=real: real_source_user with no active session is a clear
# FAIL, not a silent false-pass or a crash (the cross-user PipeWire/
# PulseAudio bridge - lib/pigeoncam-common.sh's resolve_pulse_bridge_env) --
REAL_USER=$(id -un)
NO_SESSION_BASE="$WORK/run-user-empty"
mkdir -p "$NO_SESSION_BASE"

CONFIG_AUDIO2="$WORK/config-audio2.yaml"
write_test_config "$CONFIG_AUDIO2" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" \
       -e 's#channel_live_url: .*#channel_live_url: ""#' \
       -e 's#mode: synthetic#mode: real#' \
       -e 's#real_source: ""#real_source: "test-mic"#' \
       -e "s#real_source_user: \"\"#real_source_user: \"${REAL_USER}\"#" \
    "$CONFIG_AUDIO2"
out=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_AUDIO2" \
      PIGEONCAM_PULSE_RUNTIME_BASE="$NO_SESSION_BASE" \
      "$REPO_ROOT/bin/pigeoncam-doctor.sh" 2>&1); rc=$?
assert_contains "$out" "FAIL  audio device" "real_source_user with no active session: flagged FAIL, not a silent pass"
assert_contains "$out" "no active PipeWire/PulseAudio session" "real_source_user with no active session: message explains why"

# --- audio.mode=real: an active session with the source enumerable is PASS
HAS_SESSION_BASE="$WORK/run-user-active"
mkdir -p "$HAS_SESSION_BASE/$(id -u)/pulse"
python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
" "$HAS_SESSION_BASE/$(id -u)/pulse/native"
out=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_AUDIO2" \
      PIGEONCAM_PULSE_RUNTIME_BASE="$HAS_SESSION_BASE" \
      FAKE_PACTL_SOURCES="test-mic" \
      "$REPO_ROOT/bin/pigeoncam-doctor.sh" 2>&1); rc=$?
assert_contains "$out" "PASS  audio device" "real_source_user with an active session and enumerable source: PASS"

# --- doctor itself doesn't crash without yq/jq on PATH --------------------
EMPTY_BIN="$WORK/empty-bin"
mkdir -p "$EMPTY_BIN"
for c in bash cat grep sed find sort mkdir rm stat date basename dirname printf timeout; do
    p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$EMPTY_BIN/$c"
done
out=$(PATH="$EMPTY_BIN" PIGEONCAM_CONFIG="$CONFIG" "$REPO_ROOT/bin/pigeoncam-doctor.sh" 2>&1); rc=$?
assert_true "doctor exits non-zero (not a crash) when yq/jq are missing" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  config parser" "missing yq/jq is reported as its own clear failure, not a stack trace"

test_summary_and_exit

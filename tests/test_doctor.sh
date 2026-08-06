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
# Also B2: a WARN (never FAIL, per FR12) when current free space on the
# archive dir looks tight against the sizing estimate's daily rate.
# Also B3: a WARN when reencode.enabled=true but nothing (systemd timer,
# crontab, /etc/cron.d) appears to actually invoke it.

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

# item 3c: check_timer_intervals reads *.timer files from a directory
# (default /etc/systemd/system - PIGEONCAM_DOCTOR_SYSTEMD_DIR overrides it
# for tests, same pattern as PIGEONCAM_DOCTOR_UDEV_DIRS/_CRON_D_DIR below).
# The real shipped timer files already match write_test_config's own
# defaults (watchdog: 30s, status-check: 180s - by design, the whole point
# of item 3c), so copying them verbatim is a genuine "everything in sync"
# fixture, not a hand-crafted one. pigeoncam-rotate.timer is deliberately
# NOT part of this check (see the field-log incident in
# docs/development/INCIDENTS.md and that timer file's own comment) - its
# OnUnitActiveSec is a fixed 5min poll cadence, not youtube.rotation.interval,
# so it is copied into the fixture directory too but never compared.
SYSTEMD_DIR_GOOD="$WORK/systemd-good"
mkdir -p "$SYSTEMD_DIR_GOOD"
cp "$REPO_ROOT/systemd/pigeoncam-rotate.timer" "$REPO_ROOT/systemd/pigeoncam-watchdog.timer" \
   "$REPO_ROOT/systemd/pigeoncam-status-check.timer" "$SYSTEMD_DIR_GOOD/"

# run_doctor <v4l2_mode> <udev_dirs> [ffmpeg_mode] [config] [systemctl_state]
# [df_avail_kb] -- explicit parameters, not ambient env vars: `out=$(some_wrapper)`
# is itself just an assignment (no trailing command word), so env-var prefixes
# placed before a call written as `VAR=x out=$(run_doctor)` never actually
# reach the subprocess - bash only honors prefix-assignment exports on a line
# with a real trailing command. Passing everything as explicit args to a
# function that itself performs the real, trailing invocation sidesteps that
# trap. df_avail_kb defaults to a huge value (~954 TB) so every scenario that
# doesn't care about B2's disk-space check keeps seeing plenty of headroom.
run_doctor() {
    local v4l2_mode="$1" udev_dirs="$2" ffmpeg_mode="${3:-good}" config="${4:-$CONFIG}" systemctl_state="${5:-enabled}" df_avail_kb="${6:-999999999}" systemd_dir="${7:-$SYSTEMD_DIR_GOOD}"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$config" \
    FAKE_V4L2_MODE="$v4l2_mode" \
    PIGEONCAM_DOCTOR_UDEV_DIRS="$udev_dirs" \
    FAKE_FFMPEG_MODE="$ffmpeg_mode" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_SYSTEMCTL_ENABLED_STATE="$systemctl_state" \
    FAKE_DF_AVAIL_KB="$df_avail_kb" \
    PIGEONCAM_DOCTOR_SYSTEMD_DIR="$systemd_dir" \
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
assert_contains "$out" "PASS  archive disk space" "baseline: plenty of free space passes"
assert_not_contains "$out" "timer/config sync (pigeoncam-rotate.timer)" "item 3c baseline: rotate timer is deliberately not part of this check at all"
assert_contains "$out" "PASS  timer/config sync (pigeoncam-watchdog.timer)" "item 3c baseline: watchdog timer matches watchdog.check_interval_seconds"
assert_contains "$out" "PASS  timer/config sync (pigeoncam-status-check.timer)" "item 3c baseline: status-check timer matches external_check.poll_interval_seconds"
assert_contains "$out" "PASS  rotation interval" "baseline: the default 11h45m rotation interval is within the ~12h ceiling"
assert_not_contains "$out" "rotation schedule (solar)" "baseline: schedule: interval (the default) never runs the solar-only check at all"
assert_not_contains "$out" "archive daytime window (solar)" "baseline: daytime_mode: fixed (the default) never runs the solar-only check at all"

# --- B2: free space that the current config's daily rate would exhaust
#     within a week is a WARN (never FAIL - FR12 explicitly does not
#     enforce a storage budget) naming the actual GB free and days left --
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG" enabled 100000000); rc=$?
assert_eq "0" "$rc" "B2: low free space is a WARN, does not flip the overall exit code"
assert_contains "$out" "WARN  archive disk space" "B2: low free space relative to the daily rate is flagged WARN"
assert_contains "$out" "not enforced" "B2: WARN message is explicit that this isn't an enforced budget"

# --- B3: reencode.enabled is false by default -> no timer check at all,
#     not even a PASS line (nothing to check) ------------------------------
out=$(run_doctor good "$WORK/udev-good"); rc=$?
assert_not_contains "$out" "reencode timer" "B3: reencode.enabled=false (the default) skips the timer check entirely"

# --- B3: reencode.enabled=true - unlike every other Tier 1 feature, this
#     one ships without a systemd timer by default, so doctor best-effort
#     checks for a timer, a crontab entry, or an /etc/cron.d entry -------
CONFIG_REENCODE="$WORK/config-reencode.yaml"
write_test_config "$CONFIG_REENCODE" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" \
       -e 's#channel_live_url: .*#channel_live_url: ""#' \
       -e 's#enabled: false#enabled: true#' \
    "$CONFIG_REENCODE"

CRON_D_EMPTY="$WORK/cron.d-empty"
CRON_D_MATCH="$WORK/cron.d-match"
mkdir -p "$CRON_D_EMPTY" "$CRON_D_MATCH"
echo "0 3 * * 0 root /opt/PigeonCamSteward/bin/pigeoncam-reencode.sh" > "$CRON_D_MATCH/pigeoncam-reencode"

# run_doctor_reencode <systemctl_state> [crontab_output] [cron_d_dir] --
# separate from run_doctor above rather than growing its parameter list
# further: this scenario set needs its own config (reencode.enabled=true)
# and its own cron-related knobs that no other scenario in this file cares
# about.
run_doctor_reencode() {
    local systemctl_state="$1" crontab_output="${2:-}" cron_d_dir="${3:-$CRON_D_EMPTY}"
    PATH="$FAKE_BIN:$PATH" \
    PIGEONCAM_CONFIG="$CONFIG_REENCODE" \
    FAKE_V4L2_MODE=good \
    PIGEONCAM_DOCTOR_UDEV_DIRS="$WORK/udev-good" \
    FAKE_FFMPEG_MODE=good \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    FAKE_SYSTEMCTL_ENABLED_STATE="$systemctl_state" \
    FAKE_DF_AVAIL_KB=999999999 \
    FAKE_CRONTAB_OUTPUT="$crontab_output" \
    PIGEONCAM_DOCTOR_CRON_D_DIR="$cron_d_dir" \
    PIGEONCAM_DOCTOR_SYSTEMD_DIR="$SYSTEMD_DIR_GOOD" \
    "$REPO_ROOT/bin/pigeoncam-doctor.sh"
}

out=$(run_doctor_reencode enabled)
assert_contains "$out" "PASS  reencode timer" "B3: reencode.enabled=true with pigeoncam-reencode.timer enabled passes"

out=$(run_doctor_reencode disabled "0 3 * * 0 /opt/PigeonCamSteward/bin/pigeoncam-reencode.sh")
assert_contains "$out" "PASS  reencode timer" "B3: reencode.enabled=true with a matching crontab entry passes"
assert_contains "$out" "crontab entry" "B3: crontab-match message names the crontab specifically"

out=$(run_doctor_reencode disabled "" "$CRON_D_MATCH")
assert_contains "$out" "PASS  reencode timer" "B3: reencode.enabled=true with a matching /etc/cron.d-style entry passes"

out=$(run_doctor_reencode not-found)
assert_contains "$out" "WARN  reencode timer" "B3: reencode.enabled=true with nothing wired up anywhere is flagged WARN"
assert_contains "$out" "run bin/pigeoncam-reencode.sh manually" "B3: WARN message gives the actual fix"

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

# item 2a's ERR trap regression: doctor.sh deliberately runs without
# set -e and returns non-zero as its own normal, intended way to report
# "checks failed" (see main()'s `(( FAIL == 0 ))`) - not a bug. Caught
# while adding item 3c: an unguarded `main "$@"` at the bottom of the
# script made that expected non-zero return trip the ERR trap's "this is
# a bug, not a normal fault" diagnostic on every single doctor run that
# finds anything wrong, which is most of them. Captures stderr explicitly
# (run_doctor's own $out above does not) since that's where the trap's
# log_error output lands.
out_err=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG" FAKE_V4L2_MODE=yuyv_trap \
    PIGEONCAM_DOCTOR_UDEV_DIRS="$WORK/udev-good" FAKE_FFMPEG_MODE=good \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_SYSTEMCTL_ENABLED_STATE=enabled \
    FAKE_DF_AVAIL_KB=999999999 PIGEONCAM_DOCTOR_SYSTEMD_DIR="$SYSTEMD_DIR_GOOD" \
    "$REPO_ROOT/bin/pigeoncam-doctor.sh" 2>&1)
assert_not_contains "$out_err" "this is a bug, not a normal fault" \
    "a legitimate doctor FAIL does not spuriously trip the ERR trap's 'this is a bug' diagnostic"

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
      PIGEONCAM_DOCTOR_SYSTEMD_DIR="$SYSTEMD_DIR_GOOD" \
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
      PIGEONCAM_DOCTOR_SYSTEMD_DIR="$SYSTEMD_DIR_GOOD" \
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

# --- the tier2: -> youtube_api: rename. There is no dual-read fallback in
#     the scripts, so this check IS the migration: an un-migrated config
#     silently reads as "YouTube API access disabled", which looks like a
#     healthy system right up until a stuck broadcast needs recovering and
#     nothing happens. Must therefore FAIL, and must name the exact edits.
CONFIG_LEGACY="$WORK/config-legacy.yaml"
write_test_config "$CONFIG_LEGACY" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_LEGACY"
printf 'tier2:\n  enabled: true\n' >> "$CONFIG_LEGACY"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_LEGACY"); rc=$?
assert_true "legacy tier2: block makes doctor exit non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  config format (legacy tier2: block)" "legacy tier2: block is flagged FAIL, not a silent no-op"
assert_contains "$out" "youtube_api:" "the failure names the new block name"
assert_contains "$out" "youtube_api_token.json" "the failure names the credential files that also need renaming"

# The migrated form must be clean - otherwise the check would nag forever.
out=$(run_doctor good "$WORK/udev-good"); rc=$?
assert_not_contains "$out" "legacy tier2" "a migrated config (config.example.yaml's shape) produces no legacy finding"

# --- unrecognized-key scan: the belt to the legacy-key check above. Catches
#     any key that parses as valid YAML and looks configured but is never
#     actually read by any script - a typo, a renamed key, or a value
#     invented for a template that didn't match the real code. Found (and
#     motivated) by two real instances during a manual config migration:
#     watchdog.usb_reset.escalation_cooldown_seconds (the real key is
#     cooldown_seconds) and audio.thread_queue_size (not read by anything -
#     only camera.thread_queue_size is). ------------------------------------
assert_contains "$out" "PASS  config keys (unrecognized-key scan)" "the shipped config shape gets an explicit PASS - the check must not cry wolf on real config"
assert_not_contains "$out" "WARN  config keys (unrecognized-key scan)" "the shipped config shape produces no unrecognized-key WARN"

CONFIG_TYPO="$WORK/config-typo.yaml"
write_test_config "$CONFIG_TYPO" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_TYPO"
cat >> "$CONFIG_TYPO" <<'EOF'
watchdog:
  frame_freze: true
EOF
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_TYPO"); rc=$?
assert_eq "0" "$rc" "an unrecognized key is a WARN, does not flip the overall exit code"
assert_contains "$out" "WARN  config keys (unrecognized-key scan)" "a typo'd key (frame_freze) is flagged"
assert_contains "$out" "watchdog.frame_freze" "the WARN names the exact unrecognized key, dotted path and all"
assert_contains "$out" "config.example.yaml" "the WARN points at the reference file to check spelling against"

# Real values used elsewhere in this file also must not misfire - dotted
# strings that AREN'T config keys (docs paths, log-event labels, JSON field
# names in api/rotate_via_api.py) must never leak into the recognized set in
# a way that then hides an actually-wrong key with a coincidentally similar
# shape. Spot check: a key one segment truncated from a real one must still
# be flagged, proving the check isn't just matching "starts with a known
# prefix".
CONFIG_TRUNC="$WORK/config-trunc.yaml"
write_test_config "$CONFIG_TRUNC" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_TRUNC"
cat >> "$CONFIG_TRUNC" <<'EOF'
watchdog:
  usb_reset:
    cooldown: 900
EOF
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_TRUNC")
assert_contains "$out" "watchdog.usb_reset.cooldown" "a truncated/near-miss key name (cooldown vs cooldown_seconds) is still flagged, not fuzzy-matched as close enough"

# --- item 3c: pigeoncam-watchdog.timer's OnUnitActiveSec hand-edited out of
#     sync with watchdog.check_interval_seconds - a WARN (never FAIL: the
#     values changing rarely and by hand is exactly what B2/B3 already treat
#     as non-fatal elsewhere in this script), naming both actual values.
#     (Not pigeoncam-rotate.timer - see the comment above the fixture setup:
#     that timer is deliberately excluded from this check entirely.) -------
SYSTEMD_DIR_MISMATCH="$WORK/systemd-mismatch"
mkdir -p "$SYSTEMD_DIR_MISMATCH"
cp "$SYSTEMD_DIR_GOOD"/*.timer "$SYSTEMD_DIR_MISMATCH/"
sed -i 's/^OnUnitActiveSec=.*/OnUnitActiveSec=10h/' "$SYSTEMD_DIR_MISMATCH/pigeoncam-watchdog.timer"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG" enabled 999999999 "$SYSTEMD_DIR_MISMATCH"); rc=$?
assert_eq "0" "$rc" "item 3c: a timer/config mismatch is a WARN, does not flip the overall exit code"
assert_contains "$out" "WARN  timer/config sync (pigeoncam-watchdog.timer)" "item 3c: a hand-edited-out-of-sync watchdog timer is flagged WARN"
assert_contains "$out" "OnUnitActiveSec=10h" "item 3c: WARN message names the actual timer value"
assert_contains "$out" "watchdog.check_interval_seconds=30" "item 3c: WARN message names the actual config value"
assert_contains "$out" "PASS  timer/config sync (pigeoncam-status-check.timer)" "item 3c: the untouched status-check timer still passes independently"
assert_not_contains "$out" "timer/config sync (pigeoncam-rotate.timer)" "item 3c: rotate timer stays excluded from this check even when other timers mismatch"

# --- item 3c: timer not installed yet - WARN, not FAIL, matching
#     check_start_limit's own leniency for "step 5 not reached yet" -------
SYSTEMD_DIR_MISSING="$WORK/systemd-missing"
mkdir -p "$SYSTEMD_DIR_MISSING"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG" enabled 999999999 "$SYSTEMD_DIR_MISSING"); rc=$?
assert_eq "0" "$rc" "item 3c: no installed timers is a WARN, does not flip the overall exit code"
assert_contains "$out" "WARN  timer/config sync (pigeoncam-watchdog.timer)" "item 3c: a not-yet-installed watchdog timer is flagged WARN"
assert_contains "$out" "not installed yet" "item 3c: WARN message is clear about why"
assert_not_contains "$out" "timer/config sync (pigeoncam-rotate.timer)" "item 3c: no installed timers still never mentions rotate timer, since it's not checked"

# --- solar scheduling: youtube.rotation.schedule: solar and
#     archive.daytime_mode: solar each need location.latitude/longitude to
#     actually run - hour_is_daytime/check_rotation_due already fall back
#     to the fixed behaviour on their own if it's missing (never blocking
#     the feature they gate), but that fallback means the operator asked
#     for a mode that silently isn't running, which is a misconfiguration
#     worth a hard FAIL here, the same reasoning check_youtube_api already
#     uses for its own missing prerequisites. -------------------------------
CONFIG_SOLAR_NOLOC="$WORK/config-solar-noloc.yaml"
write_test_config "$CONFIG_SOLAR_NOLOC" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_SOLAR_NOLOC"
sed -i -e 's/schedule: interval/schedule: solar/' -e 's/daytime_mode: fixed/daytime_mode: solar/' "$CONFIG_SOLAR_NOLOC"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_SOLAR_NOLOC"); rc=$?
assert_true "solar scheduling without location: doctor exits non-zero" bash -c "[ '$rc' -ne 0 ]"
assert_contains "$out" "FAIL  rotation schedule (solar)" "solar rotation without location.longitude is flagged FAIL"
assert_contains "$out" "location.longitude" "the rotation FAIL names the missing key"
assert_contains "$out" "FAIL  archive daytime window (solar)" "solar archive daytime without location.latitude/longitude is flagged FAIL"
assert_contains "$out" "location.latitude" "the archive FAIL names the missing latitude key"

# Same ERR-trap-noise regression this file already checks for the
# yuyv_trap scenario above, exercised here because check_archive_daytime_mode
# is a genuine instance found while writing this feature: its FAIL branches
# set ok=false, and the function's ORIGINAL last statement was `$ok &&
# result PASS ...` - as the function's own final command, that made the
# whole function return 1 whenever ok=false, which (called unguarded from
# main(), not inside an if/&&/list) tripped the ERR trap on every FAIL this
# check reports. Fixed to `if $ok; then result PASS ...; fi`, which always
# returns 0. Captures stderr explicitly, same reason as the yuyv_trap check.
out_err=$(PATH="$FAKE_BIN:$PATH" PIGEONCAM_CONFIG="$CONFIG_SOLAR_NOLOC" FAKE_V4L2_MODE=good \
    PIGEONCAM_DOCTOR_UDEV_DIRS="$WORK/udev-good" FAKE_FFMPEG_MODE=good \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_SYSTEMCTL_ENABLED_STATE=enabled \
    FAKE_DF_AVAIL_KB=999999999 PIGEONCAM_DOCTOR_SYSTEMD_DIR="$SYSTEMD_DIR_GOOD" \
    "$REPO_ROOT/bin/pigeoncam-doctor.sh" 2>&1)
assert_not_contains "$out_err" "this is a bug, not a normal fault" \
    "check_archive_daytime_mode's FAIL path does not spuriously trip the ERR trap"

# --- solar scheduling: location present - PASS, and the rotation check
#     prints today's actual computed boundaries (the single most useful
#     line this feature can offer - turns an abstract config setting into
#     concrete clock times) ------------------------------------------------
CONFIG_SOLAR_LOC="$WORK/config-solar-loc.yaml"
write_test_config "$CONFIG_SOLAR_LOC" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_SOLAR_LOC"
sed -i \
    -e 's/schedule: interval/schedule: solar/' \
    -e 's/daytime_mode: fixed/daytime_mode: solar/' \
    -e 's/latitude: ""/latitude: 48.8566/' \
    -e 's/longitude: ""/longitude: 2.3522/' \
    "$CONFIG_SOLAR_LOC"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_SOLAR_LOC")
assert_contains "$out" "PASS  rotation schedule (solar)" "solar rotation with a valid location passes"
assert_contains "$out" "today's rotation boundaries" "the PASS line prints today's actual boundaries, not just a bare OK"
assert_contains "$out" "PASS  archive daytime window (solar)" "solar archive daytime with a valid location passes"

# --- rotation interval ceiling - independent of schedule mode: an
#     interval already past YouTube's ~12h continuous-archive ceiling
#     defeats FR14's whole purpose regardless of interval vs solar -------
CONFIG_LONG_INTERVAL="$WORK/config-long-interval.yaml"
write_test_config "$CONFIG_LONG_INTERVAL" "$RUN_DIR" "$SEGMENT_DIR" "$KEY_FILE"
sed -i -e "s#device: /dev/null#device: ${FAKE_DEVICE}#" -e 's#channel_live_url: .*#channel_live_url: ""#' "$CONFIG_LONG_INTERVAL"
sed -i 's/interval: "11h45m"/interval: "12h30m"/' "$CONFIG_LONG_INTERVAL"
out=$(run_doctor good "$WORK/udev-good" good "$CONFIG_LONG_INTERVAL"); rc=$?
assert_eq "0" "$rc" "an over-ceiling rotation interval is a WARN, does not flip the overall exit code"
assert_contains "$out" "WARN  rotation interval" "a rotation interval exceeding ~11h50m is flagged WARN"
assert_contains "$out" "12h30m" "the WARN names the actual configured interval"

test_summary_and_exit

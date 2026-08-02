#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_systemd_units.sh - real systemd-analyze verify against every unit
# in systemd/, run together (not one file at a time), plus a plain-grep
# check that item 2b's OnFailure=pigeoncam-failure-notify@%n wiring is
# present on the five units that need it. NOTE: systemd-analyze verify
# (without --root, which would need a full mirrored systemd install) does
# NOT validate that OnFailure= targets resolve - confirmed empirically by
# removing the template unit file and seeing verify still pass clean. So
# verify only covers unit-file syntax here; the OnFailure= wiring itself
# is checked separately, by grep, below.
#
# This checkout never lives at /opt/PigeonCamSteward (every ExecStart= is
# an absolute path there, by this project's own convention - see
# lib/pigeoncam-common.sh's PIGEONCAM_PROJECT_ROOT comment on why runtime
# messages use absolute paths), so verify's "Command ... is not
# executable" complaint is expected and constant for every unit, every
# run, regardless of correctness - confirmed empirically: introducing a
# deliberately bogus directive into a copy of a real unit produces an
# ADDITIONAL, distinct error line alongside that one, never in place of
# it. So the check here is not "zero output" but "no output beyond
# exactly that one expected shape per unit".
#
# Skips gracefully if systemd-analyze isn't on PATH - this project has no
# hard dependency on it, only an opportunistic use of it here.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_systemd_units.sh ==="

if ! command -v systemd-analyze >/dev/null 2>&1; then
    echo "  SKIP - systemd-analyze not available in this environment"
    test_summary_and_exit
fi

mapfile -t UNIT_FILES < <(cd "$REPO_ROOT/systemd" && ls -- *.service *.timer 2>/dev/null)
assert_true "at least one unit file exists to verify" bash -c "(( ${#UNIT_FILES[@]} > 0 ))"

out=$(cd "$REPO_ROOT/systemd" && systemd-analyze verify "${UNIT_FILES[@]}" 2>&1)

# The one expected complaint shape, once per unit that has an ExecStart=
# (timers don't). Anything that doesn't match this exact shape is real.
unexpected=$(grep -v -E '^[A-Za-z0-9@._-]+\.(service|timer): Command /opt/PigeonCamSteward/bin/[A-Za-z0-9._-]+\.sh is not executable: No such file or directory$' <<<"$out")

# (assert_eq's own message always prints, even on success - keep it short
# and dump the full verify output separately, only when this is failing)
if [[ -n "$unexpected" ]]; then
    echo "  --- full systemd-analyze verify output ---"
    echo "$out"
fi
assert_eq "" "$unexpected" "systemd-analyze verify: no errors beyond the expected 'not executable' complaint (this checkout isn't at /opt/PigeonCamSteward)"

# The specific thing item 2b added. NOTE: systemd-analyze verify (without
# --root, which would need a full mirrored systemd install to work here)
# does NOT validate that OnFailure= targets actually resolve - confirmed
# empirically by removing the template unit file and observing verify
# still pass with no new complaint. So this cannot be a verify-output
# check; it's a plain grep against the unit files themselves instead.
covered_units=(
    pigeoncam-watchdog.service
    pigeoncam-status-check.service
    pigeoncam-rotate.service
    pigeoncam-archive-trim.service
    pigeoncam-ytdlp-update.service
)
for u in "${covered_units[@]}"; do
    assert_contains "$(cat "$REPO_ROOT/systemd/$u")" "OnFailure=pigeoncam-failure-notify@%n.service" \
        "$u has OnFailure=pigeoncam-failure-notify@%n.service wired"
done

# Restart=always means pigeoncam-stream.service "fails" routinely by
# design (see bin/pigeoncam-failure-notify.sh's header) - OnFailure= there
# would just be noise, so it must NOT be wired.
assert_not_contains "$(cat "$REPO_ROOT/systemd/pigeoncam-stream.service")" "OnFailure=" \
    "pigeoncam-stream.service deliberately has no OnFailure= (Restart=always makes failure routine)"

assert_true "systemd/pigeoncam-failure-notify@.service exists (the OnFailure= target above)" \
    [ -f "$REPO_ROOT/systemd/pigeoncam-failure-notify@.service" ]

assert_contains "$(cat "$REPO_ROOT/systemd/pigeoncam-failure-notify@.service")" "ExecStart=/opt/PigeonCamSteward/bin/pigeoncam-failure-notify.sh %i" \
    "pigeoncam-failure-notify@.service passes the instance name (%i) through to the script"

test_summary_and_exit

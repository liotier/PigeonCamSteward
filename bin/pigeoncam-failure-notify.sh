#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-failure-notify.sh - item 2b of the 2026-08-02 architecture
# review: the belt to lib/pigeoncam-common.sh's ERR trap (item 2a). The
# ERR trap guarantees a diagnostic reaches the journal whenever a script
# that sources the lib dies unexpectedly - but that alone never reaches
# notify_command, since the trap only logs. Deaths the trap can't even
# catch (OOM kill, SIGKILL, an interpreter that never got far enough to
# source the lib at all) leave nothing in the journal either.
#
# Invoked via each covered unit's OnFailure=pigeoncam-failure-notify@%n.service
# (see systemd/pigeoncam-failure-notify@.service), which systemd fires
# whenever that unit enters the failed state, whatever the cause. Takes
# the failed unit's name as $1 (systemd's %i, the template instance) and
# routes it through the same notify_command channel as every other
# escalation in this project, so "a reliability script itself broke" is
# never silent again.
#
# Deliberately NOT wired to pigeoncam-stream.service: Restart=always (FR6)
# means that unit "fails" routinely and by design during normal recovery,
# and OnFailure= there would just be noise. Its own coverage comes from
# the watchdog and status-check layers, which this script backs up.
#
# A genuine rotation failure already calls notify_escalation ROTATION_FAILED
# itself before exiting non-zero (bin/pigeoncam-rotate.sh) - OnFailure=
# still fires on top of that, so a rotation failure notifies twice.
# Accepted deliberately: the residual value here is a rotate.sh crash
# NEITHER of its own failure paths anticipated, which is exactly the gap
# this script exists to close, and an occasional duplicate notification
# for an already-serious event is a small price for that.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-failure-notify"

main() {
    local failed_unit="${1:?usage: pigeoncam-failure-notify.sh <failed-unit-name>}"
    notify_escalation UNIT_FAILED "${failed_unit} entered the failed state - see journalctl -u ${failed_unit} for the actual error"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

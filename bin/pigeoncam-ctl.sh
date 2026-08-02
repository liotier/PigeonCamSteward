#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-ctl.sh - single-command start/stop/restart/enable/disable/status
# for every PigeonCamSteward unit at once, instead of naming
# pigeoncam-stream.service and five pigeoncam-*.timer units by hand each
# time. Assumes README Quickstart step 5 already installed them (copied the
# unit files, ran daemon-reload) - this only ever calls systemctl against
# units systemd already knows about, never touches unit files or config.

set -uo pipefail   # deliberately no -e: one unit failing shouldn't abort the rest; we keep going and aggregate

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-ctl"

usage() {
    cat <<EOF
Usage: $(basename "$0") <start|stop|restart|enable|disable|status>

Applies systemctl <verb> to every unit in $PIGEONCAM_PROJECT_ROOT/systemd/ at
once: pigeoncam-stream.service and the watchdog/status-check/rotate/
archive-trim/ytdlp-update timers. start/restart/enable act in that order;
stop/disable act in reverse, so the long-running stream service is the last
thing stopped/disabled and the first thing started/enabled.

status reports each unit's active/enabled state and exits non-zero if any
unit is not active and enabled (or static).
EOF
}

# reversed_units - PIGEONCAM_ALL_UNITS back to front, one per line, for
# stop/disable. Callers read it via `mapfile` (not `$(...)` word-splitting)
# so unit names are never re-split/re-globbed.
reversed_units() {
    local -i i
    for (( i = ${#PIGEONCAM_ALL_UNITS[@]} - 1; i >= 0; i-- )); do
        printf '%s\n' "${PIGEONCAM_ALL_UNITS[i]}"
    done
}

# apply <systemctl-verb> <unit...> - runs the verb against every unit given,
# even if one fails, then reports which (if any) failed. Mirrors doctor.sh's
# own "keep going and aggregate" philosophy: a typo'd or not-yet-installed
# unit shouldn't stop e.g. `stop` from reaching the rest.
apply() {
    local verb="$1"; shift
    local -a failed=()
    local u
    for u in "$@"; do
        log_info "systemctl $verb $u"
        systemctl "$verb" "$u" || failed+=("$u")
    done
    if (( ${#failed[@]} > 0 )); then
        log_error "$verb failed for: ${failed[*]}"
        return 1
    fi
    log_info "$verb: done (${#PIGEONCAM_ALL_UNITS[@]} units)"
}

cmd_status() {
    local u active enabled rc=0
    printf '%-32s %-10s %s\n' "UNIT" "ACTIVE" "ENABLED"
    for u in "${PIGEONCAM_ALL_UNITS[@]}"; do
        active=$(systemctl is-active "$u" 2>/dev/null || true)
        enabled=$(systemctl is-enabled "$u" 2>/dev/null || true)
        printf '%-32s %-10s %s\n' "$u" "${active:-unknown}" "${enabled:-unknown}"
        [[ "$active" == "active" ]] || rc=1
        case "$enabled" in
            enabled|static) ;;
            *) rc=1 ;;
        esac
    done
    return "$rc"
}

main() {
    if [[ $# -ne 1 ]]; then
        usage >&2
        exit 2
    fi
    require_cmd systemctl

    # rc is collected and then exited explicitly, rather than letting the
    # verb's own return status fall off the end as main's: a non-zero exit
    # from this script is a *report* (status found a unit down; a verb
    # failed for some units), not a fault, and a bare non-zero return from
    # the top-level `main "$@"` would trip lib/pigeoncam-common.sh's ERR
    # trap and print "this is a bug, not a normal fault" at an operator
    # running `pigeoncam-ctl.sh status` on a deliberately stopped stream.
    # A plain `exit N` does not trip the trap; real failures deeper inside
    # still do.
    local -a reversed
    local rc=0
    case "$1" in
        start)   apply start   "${PIGEONCAM_ALL_UNITS[@]}" || rc=$? ;;
        restart) apply restart "${PIGEONCAM_ALL_UNITS[@]}" || rc=$? ;;
        enable)  apply enable  "${PIGEONCAM_ALL_UNITS[@]}" || rc=$? ;;
        stop)    mapfile -t reversed < <(reversed_units); apply stop    "${reversed[@]}" || rc=$? ;;
        disable) mapfile -t reversed < <(reversed_units); apply disable "${reversed[@]}" || rc=$? ;;
        status)  cmd_status || rc=$? ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Bare on purpose - main() exits explicitly. See the matching note in
    # bin/pigeoncam-doctor.sh for why `main "$@" || exit $?` must never be
    # used to silence a spurious ERR-trap message: it disables set -e
    # inside main and everything it calls.
    main "$@"
fi

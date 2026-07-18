#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-watchdog.sh - FR7: frame-progress stall detection, independent of
# systemd's process-level Restart=always (which cannot see a hang, only an
# exit). FR7b: escalates to a USB-level device reset if a plain restart is
# followed by another stall detection within the next check interval, i.e.
# the restart did not actually clear the fault.
#
# Invoked periodically as a oneshot by systemd/pigeoncam-watchdog.timer; state
# persists between invocations in $run_dir/watchdog.state.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-watchdog"

# State fields (deliberately script-global, not `local`: this is a
# short-lived oneshot invocation, not a long-running process, so there is no
# reuse/leakage concern).
last_frame=""
frame_unchanged_since=0
stall_restart_count=0

read_state() {
    local path="$1"
    last_frame=""
    frame_unchanged_since=0
    stall_restart_count=0
    if [[ -f "$path" ]]; then
        # shellcheck disable=SC1090
        source "$path"
    fi
}

write_state() {
    local path="$1"
    mkdir -p -- "$(dirname -- "$path")"
    {
        printf 'last_frame=%q\n' "$last_frame"
        printf 'frame_unchanged_since=%d\n' "$frame_unchanged_since"
        printf 'stall_restart_count=%d\n' "$stall_restart_count"
    } > "$path"
}

restart_stream() {
    log_event STALL_RESTART "restarting $PIGEONCAM_STREAM_UNIT (frame progress stalled)"
    systemctl restart "$PIGEONCAM_STREAM_UNIT"
}

escalate_usb_reset() {
    log_event USB_RESET_ESCALATION "plain restart did not clear the stall; escalating to USB-level device reset"
    if "$SCRIPT_DIR/pigeoncam-usb-reset.sh"; then
        log_event USB_RESET_ESCALATION "reset script reported success"
    else
        log_event USB_RESET_ESCALATION "reset script FAILED - device may need manual attention"
    fi
}

main() {
    local progress_file stall_timeout state_path
    progress_file=$(cfg '.watchdog.progress_file' /run/pigeoncam/progress)
    stall_timeout=$(cfg '.watchdog.stall_timeout_seconds' 60)
    state_path=$(marker_path watchdog.state)

    if [[ ! -f "$progress_file" ]]; then
        log_info "progress file does not exist yet ($progress_file) - stream starting up, nothing to check"
        exit 0
    fi

    read_state "$state_path"

    local cur_frame age now
    cur_frame=$(progress_last_frame "$progress_file")
    age=$(progress_age_seconds "$progress_file")
    now=$(date +%s)

    # Secondary signal (FR7): has the frame counter itself been stuck,
    # independent of mtime? Track how long the *same* frame value has been
    # observed across checks, separately from file staleness - this catches
    # a pathological case where something keeps touching the file without
    # ffmpeg actually making encode progress.
    if [[ -n "$cur_frame" && "$cur_frame" == "$last_frame" && "$frame_unchanged_since" != 0 ]]; then
        : # still stuck on the same value; frame_unchanged_since stays put
    else
        frame_unchanged_since=$now
    fi
    last_frame="$cur_frame"

    local frame_stuck_seconds=$(( now - frame_unchanged_since ))

    local stalled=false
    if (( age >= stall_timeout )); then
        stalled=true
    elif [[ -n "$cur_frame" ]] && (( frame_stuck_seconds >= stall_timeout )); then
        stalled=true
    fi

    if $stalled; then
        log_warn "stall detected: progress age=${age}s frame_stuck=${frame_stuck_seconds}s (timeout ${stall_timeout}s), last frame=${cur_frame:-unknown}"

        local usb_reset_enabled=false escalate_after
        if cfg_bool '.watchdog.usb_reset.enabled' true; then
            usb_reset_enabled=true
        fi
        escalate_after=$(cfg '.watchdog.usb_reset.escalate_after_restarts' 1)

        if $usb_reset_enabled && (( stall_restart_count >= escalate_after )); then
            escalate_usb_reset
            stall_restart_count=0
        else
            stall_restart_count=$(( stall_restart_count + 1 ))
        fi
        restart_stream

        # A fresh ffmpeg process is about to start from frame 0 in a
        # freshly truncated progress file; forget frame-tracking state so
        # the next check compares against the new run, not the dead one.
        # stall_restart_count is deliberately preserved (reset above only
        # on escalation) - that persistence across exactly this restart is
        # what makes another stall within the *next* check interval trip
        # the escalation branch instead of just restarting forever.
        last_frame=""
        frame_unchanged_since=0
        write_state "$state_path"
    else
        stall_restart_count=0
        write_state "$state_path"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

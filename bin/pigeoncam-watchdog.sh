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
last_usb_reset_epoch=0

read_state() {
    local path="$1"
    last_frame=""
    frame_unchanged_since=0
    stall_restart_count=0
    last_usb_reset_epoch=0
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
        printf 'last_usb_reset_epoch=%d\n' "$last_usb_reset_epoch"
    } > "$path"
}

restart_stream() {
    log_event STALL_RESTART "restarting $PIGEONCAM_STREAM_UNIT (frame progress stalled)"
    systemctl restart "$PIGEONCAM_STREAM_UNIT"
}

escalate_usb_reset() {
    notify_escalation USB_RESET_ESCALATION "plain restart did not clear the stall; escalating to USB-level device reset"
    if "$SCRIPT_DIR/pigeoncam-usb-reset.sh"; then
        notify_escalation USB_RESET_ESCALATION "reset script reported success"
    else
        notify_escalation USB_RESET_ESCALATION "reset script FAILED - device may need manual attention"
    fi
}

main() {
    local progress_file stall_timeout state_path
    progress_file=$(cfg '.watchdog.progress_file' /run/pigeoncam/progress)
    stall_timeout=$(cfg '.watchdog.stall_timeout_seconds' 60)
    state_path=$(marker_path watchdog.state)

    # Only ffmpeg *hanging while still running* is this script's job (FR7,
    # see the header comment) - a stopped unit isn't hung, it's stopped,
    # whether that's the deliberate gap in restart-mode rotation
    # (pigeoncam-rotate.sh's stop -> sleep min_gap_seconds -> start),
    # systemd cycling between Restart=always attempts, or an administrator
    # stopping the unit on purpose. Without this check the watchdog fights
    # all three: with a 30s check interval and a 60s stall_timeout, it's
    # essentially guaranteed to see the stale progress file mid-rotation-gap
    # and restart the stream before the field-measured ~100s the archive
    # clock actually needs to reset, silently defeating restart-mode
    # rotation's entire purpose (caught in review; api-mode rotation, in
    # use on this deployment, never stops the unit for a gap so hasn't hit
    # it here, but restart mode is the shipped default and would hit this
    # on every single rotation).
    if ! systemctl is-active --quiet "$PIGEONCAM_STREAM_UNIT"; then
        log_info "$PIGEONCAM_STREAM_UNIT is not active - nothing to check (stopped for rotation, maintenance, or between Restart=always attempts)"
        exit 0
    fi

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

        local usb_reset_enabled=false escalate_after cooldown_seconds
        if cfg_bool '.watchdog.usb_reset.enabled' true; then
            usb_reset_enabled=true
        fi
        escalate_after=$(cfg '.watchdog.usb_reset.escalate_after_restarts' 1)
        cooldown_seconds=$(cfg '.watchdog.usb_reset.cooldown_seconds' 300)

        # last_usb_reset_epoch starts at 0 (see read_state), so "never reset
        # before" always satisfies the cooldown and doesn't block the first
        # escalation. The cooldown exists because a stall that a device
        # reset genuinely can't fix (dead cable, failed hardware) would
        # otherwise re-trigger FR7b every other check forever - a plain
        # restart failing to clear the fault is expected and cheap, but
        # hammering a physical USB reset at that cadence indefinitely is a
        # meaningfully more disruptive escalation for no added benefit past
        # the first attempt or two (caught in review: nothing previously
        # stopped this).
        local since_last_reset=$(( now - last_usb_reset_epoch ))
        if $usb_reset_enabled && (( stall_restart_count >= escalate_after )); then
            if (( since_last_reset >= cooldown_seconds )); then
                escalate_usb_reset
                stall_restart_count=0
                last_usb_reset_epoch=$now
            else
                log_info "would escalate to USB reset, but cooldown active (${since_last_reset}s of ${cooldown_seconds}s since the last reset) - restarting the service only"
                stall_restart_count=$(( stall_restart_count + 1 ))
            fi
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

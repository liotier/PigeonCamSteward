#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# nestcam-rotate.sh - FR14: scheduled broadcast rotation to stay under
# YouTube's ~12h continuous-archive ceiling. A deliberate stop -> gap ->
# start sequence, not a bare `systemctl restart`: field testing established
# that a near-instant reconnect resumes the *same* broadcast, leaving the
# archive clock running rather than reset (SPEC.md §5.4).
#
# Invoked periodically by systemd/nestcam-rotate.timer (default 11h45m).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/nestcam-common.sh
source "$SCRIPT_DIR/../lib/nestcam-common.sh"

NESTCAM_LOG_TAG="nestcam-rotate"

# current_live_id - best-effort fetch of the live video id at the /live
# redirect right now. Used only for the self-verifying before/after log
# below; never gates the rotation sequence, and failure here is never fatal
# to the rotation itself - keeping this decoupled from FR7c/d's own
# independent verification loop per SPEC.md §4's separation of concerns.
current_live_id() {
    local json
    if json=$(fetch_live_json 2>/dev/null) && [[ -n "$json" ]]; then
        jq -r '.id // empty' <<<"$json" 2>/dev/null || true
    fi
}

do_restart_rotation() {
    local min_gap
    min_gap=$(cfg '.youtube.rotation.min_gap_seconds' 150)

    local pre_id=""
    if cfg_bool '.external_check.enabled' true; then
        pre_id=$(current_live_id)
        log_info "pre-rotation live id: ${pre_id:-unknown}"
    fi

    # Marks the start of the whole rotation window (stop, through the gap,
    # through the subsequent start) so FR7c's grace period can cover it in
    # full, per FR14: "must cover the full interval-plus-gap, not just the
    # interval."
    write_epoch_marker "$(marker_path last_rotation_at)"

    log_event ROTATION_START "stopping $NESTCAM_STREAM_UNIT, gap=${min_gap}s"
    systemctl stop "$NESTCAM_STREAM_UNIT"

    sleep "$min_gap"

    log_event ROTATION_RESTART "starting $NESTCAM_STREAM_UNIT after ${min_gap}s gap"
    systemctl start "$NESTCAM_STREAM_UNIT"

    if [[ -n "$pre_id" ]]; then
        # Single bounded settle-and-check, not a retry loop: this is a
        # best-effort log line for operators/tests, not a health gate - the
        # authoritative "is this actually working" verification is FR7c/
        # FR7d's independent, already-scheduled check.
        # Overridable only via env var (not config.yaml - this is an
        # internal settle delay, not a user-facing tunable per FR16's
        # intent); the test suite shortens it so rotation tests don't each
        # eat a real 15s wait.
        sleep "${NESTCAM_ROTATE_SETTLE_DELAY:-15}"
        local post_id
        post_id=$(current_live_id)
        if [[ -z "$post_id" ]]; then
            log_info "post-rotation id check inconclusive (not live yet, or indeterminate) - FR7c will pick this up on its own schedule"
        elif [[ "$post_id" == "$pre_id" ]]; then
            log_warn "ROTATION_SAME_BROADCAST_ID: post-rotation id ($post_id) matches pre-rotation id - the archive clock was likely NOT reset (SPEC.md §5.4 residual risk). Consider Tier 2 (FR15) if this recurs."
        else
            log_info "ROTATION_NEW_BROADCAST_ID: pre=$pre_id post=$post_id"
        fi
    fi
}

do_api_rotation() {
    if ! tier2_available; then
        log_error "youtube.rotation.mode is 'api' but Tier 2 is not installed (expected a venv at api/venv/ - see docs/TIER2.md). Set rotation.mode: restart, or complete Tier 2 setup."
        exit 1
    fi
    log_event ROTATION_START "delegating to Tier 2 API rotation"
    exec "$(tier2_venv_python)" "$(tier2_script_path)"
}

main() {
    local mode
    mode=$(cfg '.youtube.rotation.mode' restart)
    case "$mode" in
        restart) do_restart_rotation ;;
        api)     do_api_rotation ;;
        *)
            log_error "unknown youtube.rotation.mode: $mode (expected restart|api)"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

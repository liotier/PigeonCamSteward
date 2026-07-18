#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# nestcam-status-check.sh - FR7c/FR7d/FR7e: independent, low-frequency
# verification that YouTube itself is actually broadcasting, since local
# frame-progress health (FR7) cannot see the "Preparing stream" hang
# (SPEC.md §3). Three-way classification (confirmed live / confirmed not
# live / indeterminate) drives action; only "confirmed not live" - reachable
# YouTube explicitly saying nothing is live - may trigger a restart.
# Indeterminate (network/DNS/extractor trouble) is logged and retried, never
# acted on, so an ISP blip can't trigger a restart storm.
#
# Invoked periodically as a oneshot by systemd/nestcam-status-check.timer;
# state persists between invocations in $run_dir/status-check.state.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/nestcam-common.sh
source "$SCRIPT_DIR/../lib/nestcam-common.sh"

NESTCAM_LOG_TAG="nestcam-status-check"

consecutive_not_live=0
current_backoff_seconds=0
next_action_at=0

read_state() {
    local path="$1"
    consecutive_not_live=0
    current_backoff_seconds=0
    next_action_at=0
    if [[ -f "$path" ]]; then
        # shellcheck disable=SC1090
        source "$path"
    fi
}

write_state() {
    local path="$1"
    mkdir -p -- "$(dirname -- "$path")"
    {
        printf 'consecutive_not_live=%d\n' "$consecutive_not_live"
        printf 'current_backoff_seconds=%d\n' "$current_backoff_seconds"
        printf 'next_action_at=%d\n' "$next_action_at"
    } > "$path"
}

reset_state() {
    consecutive_not_live=0
    current_backoff_seconds=0
    next_action_at=0
}

# FR7e: escalate past plain reconnection once max_restarts_before_escalation
# consecutive not-live restarts have failed to restore live status. Checks
# whether Tier 2 is installed (a venv at api/venv/, not just the script
# file - see lib/nestcam-common.sh's tier2_available) and logs a clear
# manual-intervention message when it isn't, per FR7e's explicit
# requirement not to restart forever with no visible indication that
# restarting isn't working.
attempt_escalation() {
    if tier2_available; then
        log_event TIER2_ESCALATION "attempting API-based broadcast recreation"
        if tier2_run --recover; then
            log_event TIER2_ESCALATION "API recovery succeeded"
        else
            log_event TIER2_ESCALATION "API recovery FAILED"
        fi
    else
        log_event ESCALATION_UNAVAILABLE "consecutive not-live restarts exhausted and Tier 2 (FR15, api/rotate_via_api.py) is not installed - manual Studio intervention may be required. See docs/TROUBLESHOOTING.md for the stuck-broadcast recovery recipe."
    fi
}

main() {
    if ! cfg_bool '.external_check.enabled' true; then
        exit 0
    fi
    require_cmd yt-dlp jq

    local grace_restart grace_rotation since_restart since_rotation
    grace_restart=$(cfg '.external_check.grace_period_after_restart_seconds' 300)
    grace_rotation=$(cfg '.external_check.grace_period_after_rotation_seconds' 480)
    since_restart=$(seconds_since_marker "$(marker_path started_at)")
    since_rotation=$(seconds_since_marker "$(marker_path last_rotation_at)")

    # FR14: rotation grace must cover the full stop->gap->start window, not
    # just the poll interval, so check it first and with its own (larger)
    # budget - a scheduled rotation firing mid-poll must never look like a
    # fault (acceptance criterion 10).
    if (( since_rotation < grace_rotation )); then
        log_info "within post-rotation grace period (${since_rotation}s < ${grace_rotation}s), skipping"
        exit 0
    fi
    if (( since_restart < grace_restart )); then
        log_info "within post-restart grace period (${since_restart}s < ${grace_restart}s), skipping"
        exit 0
    fi

    # FR7d: only act when local health is fine. If it's not, that's the
    # watchdog's (FR7/FR7b) problem to solve, not this script's - the two
    # escalation ladders must stay independent (SPEC.md §4).
    if ! local_health_ok; then
        log_info "local frame-progress is not healthy; deferring to nestcam-watchdog, taking no action this cycle"
        exit 0
    fi

    local state_path
    state_path=$(marker_path status-check.state)
    read_state "$state_path"

    local now
    now=$(date +%s)

    local json
    if ! json=$(fetch_live_json) || [[ -z "$json" ]]; then
        log_warn "INDETERMINATE: could not confirm live status (network/DNS/extractor issue?) - no action taken, will retry next cycle"
        exit 0
    fi

    local is_live vid
    if ! is_live=$(jq -r '.is_live // false' <<<"$json" 2>/dev/null); then
        log_warn "INDETERMINATE: yt-dlp output was not valid JSON - no action taken, will retry next cycle"
        exit 0
    fi
    vid=$(jq -r '.id // empty' <<<"$json" 2>/dev/null || true)

    if [[ "$is_live" == "true" ]]; then
        log_info "confirmed live (id=${vid:-unknown})"
        reset_state
        write_state "$state_path"
        exit 0
    fi

    # Confirmed not live: yt-dlp successfully extracted info for whatever
    # the /live URL currently resolves to, and it says not live - this is
    # "YouTube reachable and answering that no broadcast is live" (FR7c
    # outcome (b)), as distinct from extraction failing outright (b) above.
    log_warn "confirmed NOT live (id=${vid:-unknown})"

    # The backoff gate only suppresses further *action* once escalation has
    # already been triggered once - it must never suppress the observation
    # above, or a real recovery happening during a backoff window would go
    # unnoticed until the entire window elapsed instead of on the very next
    # poll.
    if (( next_action_at > 0 && now < next_action_at )); then
        log_info "still not live; backing off, $(( next_action_at - now ))s remaining before next action (current_backoff=${current_backoff_seconds}s)"
        exit 0
    fi

    consecutive_not_live=$(( consecutive_not_live + 1 ))

    local max_before_escalation backoff_ceiling poll_interval
    max_before_escalation=$(cfg '.external_check.max_restarts_before_escalation' 3)
    backoff_ceiling=$(cfg '.external_check.backoff_ceiling_seconds' 1800)
    poll_interval=$(cfg '.external_check.poll_interval_seconds' 180)

    if (( consecutive_not_live < max_before_escalation )); then
        log_event EXTERNAL_RESTART "restarting $NESTCAM_STREAM_UNIT (not live, attempt ${consecutive_not_live}/${max_before_escalation})"
        systemctl restart "$NESTCAM_STREAM_UNIT"
        current_backoff_seconds=0
        next_action_at=0
    else
        attempt_escalation
        if (( current_backoff_seconds == 0 )); then
            current_backoff_seconds=$poll_interval
        else
            current_backoff_seconds=$(( current_backoff_seconds * 2 ))
            (( current_backoff_seconds > backoff_ceiling )) && current_backoff_seconds=$backoff_ceiling
        fi
        next_action_at=$(( now + current_backoff_seconds ))
        log_event ESCALATION_BACKOFF "next escalation attempt in ${current_backoff_seconds}s (ceiling ${backoff_ceiling}s)"
    fi

    write_state "$state_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

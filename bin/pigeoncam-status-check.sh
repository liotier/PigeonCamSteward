#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-status-check.sh - FR7c/FR7d/FR7e: independent, low-frequency
# verification that YouTube itself is actually broadcasting, since local
# frame-progress health (FR7) cannot see the "Preparing stream" hang
# (SPEC.md §3). Three-way classification (confirmed live / confirmed not
# live / indeterminate) drives action; only "confirmed not live" - reachable
# YouTube explicitly saying nothing is live - may trigger a restart.
# Indeterminate (network/DNS/extractor trouble) is logged and retried, never
# acted on, so an ISP blip can't trigger a restart storm.
#
# Invoked periodically as a oneshot by systemd/pigeoncam-status-check.timer;
# state persists between invocations in $run_dir/status-check.state.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-status-check"

consecutive_not_live=0
current_backoff_seconds=0
next_action_at=0
last_frame_hash=""
last_frame_sample_at=0
consecutive_frozen_samples=0
consecutive_indeterminate=0

read_state() {
    local path="$1"
    consecutive_not_live=0
    current_backoff_seconds=0
    next_action_at=0
    last_frame_hash=""
    last_frame_sample_at=0
    consecutive_frozen_samples=0
    consecutive_indeterminate=0
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
        printf 'last_frame_hash=%s\n' "$last_frame_hash"
        printf 'last_frame_sample_at=%d\n' "$last_frame_sample_at"
        printf 'consecutive_frozen_samples=%d\n' "$consecutive_frozen_samples"
        printf 'consecutive_indeterminate=%d\n' "$consecutive_indeterminate"
    } > "$path"
}

reset_state() {
    consecutive_not_live=0
    current_backoff_seconds=0
    next_action_at=0
    # Frame-freeze fields deliberately NOT reset here: reset_state() runs on
    # every confirmed-live poll (see main()), but the freeze tracker samples
    # on its own, much slower cadence (frame_freeze.check_interval_seconds)
    # and must survive across the many poll cycles between samples - it's
    # cleared explicitly by reset_freeze_state() instead, only once a fresh
    # sample actually clears the freeze or a restart/escalation is issued.
}

reset_freeze_state() {
    last_frame_hash=""
    last_frame_sample_at=0
    consecutive_frozen_samples=0
}

# check_frame_freeze - see external_check.frame_freeze in config.example.yaml
# for the full rationale. Periodically (much less often than
# poll_interval_seconds - this fetches and decodes real video data, not a
# lightweight JSON call) grabs and hashes one decoded frame from the live
# URL; confirm_count consecutive identical hashes is treated as a frozen
# relay. Gated to archive.daytime_start/daytime_end (reused, not
# duplicated) - at night a near-black frame carries little real sensor
# noise to begin with, and what little remains gets quantized away by a
# rate-controlled encoder, so identical hashes there would be a false
# positive, not evidence of anything actually stuck.
#
# Returns 0 (frozen, confirmed) or 1 (not frozen / not due / not
# applicable). Only ever samples (fetches real data) or mutates state when
# a config-gated, time-gated, interval-gated sample is actually due;
# otherwise just reports whatever the last determination already was, so a
# genuinely confirmed freeze keeps driving the same remedy every poll until
# a fresh sample clears it or a restart/escalation resets the tracker.
check_frame_freeze() {
    if ! cfg_bool '.external_check.frame_freeze.enabled' false; then
        return 1
    fi

    local daytime_start daytime_end
    daytime_start=$(cfg '.archive.daytime_start' 04:00)
    daytime_end=$(cfg '.archive.daytime_end' 20:30)
    if ! hour_in_daytime "$(current_hhmm)" "$daytime_start" "$daytime_end"; then
        return 1
    fi

    local check_interval confirm_count now
    check_interval=$(cfg '.external_check.frame_freeze.check_interval_seconds' 1800)
    confirm_count=$(cfg '.external_check.frame_freeze.confirm_count' 2)
    now=$(date +%s)

    if (( now - last_frame_sample_at >= check_interval )); then
        local url timeout_s hash
        url=$(cfg '.external_check.channel_live_url')
        timeout_s=$(cfg '.external_check.frame_freeze.fetch_timeout_seconds' 20)
        hash=$(current_live_frame_hash "$url" "$timeout_s")
        last_frame_sample_at=$now

        if [[ -z "$hash" ]]; then
            log_info "frame-freeze check: could not grab a frame this cycle (network/extractor issue?) - not counted either way"
        elif [[ "$hash" == "$last_frame_hash" ]]; then
            consecutive_frozen_samples=$(( consecutive_frozen_samples + 1 ))
        else
            last_frame_hash="$hash"
            consecutive_frozen_samples=0
        fi
    fi

    (( consecutive_frozen_samples >= confirm_count ))
}

# note_indeterminate - item 5 of the 2026-08-02 architecture review: the
# three-way classification's "never act on indeterminate" rule (FR7c) is
# correct and stays exactly as-is - this adds ONLY a counter and a
# notification, never a restart or escalation, so it cannot weaken that
# invariant. Without this, a broken yt-dlp (a YouTube frontend change) or
# a persistent network fault makes every single poll indeterminate
# forever, silently: this whole health layer goes blind with nothing to
# show for it but a journal nobody is reading.
#
# Fires once every external_check.indeterminate_alert_after consecutive
# indeterminate polls (default 20; 0 disables), then re-arms rather than
# repeating - a multi-day outage produces one notice per threshold, not
# one per poll. Wording is deliberate: this reports that a SENSOR has
# gone blind, not that the stream is down, so it must not read like an
# instruction to intervene in a healthy system at 3am.
note_indeterminate() {
    consecutive_indeterminate=$(( consecutive_indeterminate + 1 ))
    local threshold
    threshold=$(cfg '.external_check.indeterminate_alert_after' 20)
    if (( threshold > 0 && consecutive_indeterminate % threshold == 0 )); then
        local minutes poll_interval
        poll_interval=$(cfg '.external_check.poll_interval_seconds' 180)
        minutes=$(( consecutive_indeterminate * poll_interval / 60 ))
        notify_escalation EXTERNAL_CHECK_BLIND "${consecutive_indeterminate} consecutive indeterminate polls (~${minutes} minutes): the external YouTube check cannot see the stream either way and has been unable to for this entire period. The stream itself may be fine - this reports that one health layer is blind, not that the stream is down. Most likely causes: yt-dlp needs updating (see pigeoncam-ytdlp-update.timer), a persistent network fault, or a YouTube frontend change."
    fi
}

# FR7e: escalate past plain reconnection once max_restarts_before_escalation
# consecutive not-live restarts have failed to restore live status. Checks
# whether Tier 2 is installed (a venv at api/venv/, not just the script
# file - see lib/pigeoncam-common.sh's tier2_available) and logs a clear
# manual-intervention message when it isn't, per FR7e's explicit
# requirement not to restart forever with no visible indication that
# restarting isn't working.
attempt_escalation() {
    local reason="$1"
    if tier2_available; then
        notify_escalation TIER2_ESCALATION "attempting API-based broadcast recreation"
        if tier2_run --recover; then
            notify_escalation TIER2_ESCALATION "API recovery succeeded"
        else
            notify_escalation TIER2_ESCALATION "API recovery FAILED"
        fi
    else
        notify_escalation ESCALATION_UNAVAILABLE "consecutive ${reason} restarts exhausted and Tier 2 ($PIGEONCAM_PROJECT_ROOT/api/rotate_via_api.py) is not installed - manual Studio intervention may be required. See $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md for the stuck-broadcast recovery recipe."
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
        log_info "local frame-progress is not healthy; deferring to pigeoncam-watchdog, taking no action this cycle"
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
        note_indeterminate
        write_state "$state_path"
        exit 0
    fi

    local is_live vid
    if ! is_live=$(jq -r '.is_live // false' <<<"$json" 2>/dev/null); then
        log_warn "INDETERMINATE: yt-dlp output was not valid JSON - no action taken, will retry next cycle"
        note_indeterminate
        write_state "$state_path"
        exit 0
    fi
    vid=$(jq -r '.id // empty' <<<"$json" 2>/dev/null || true)

    # A determinate outcome either way (live or not-live) - the external
    # check can see the stream's status again, so whatever indeterminate
    # streak preceded this is over. Reset unconditionally here, before
    # branching on is_live, so both outcomes below pick it up via
    # whichever write_state() call they eventually reach.
    consecutive_indeterminate=0

    local not_live_reason=""
    if [[ "$is_live" == "true" ]]; then
        if check_frame_freeze; then
            not_live_reason="frozen"
            log_warn "confirmed FROZEN (id=${vid:-unknown}): broadcast reports live but the decoded video frame hasn't changed across multiple samples - see external_check.frame_freeze in config.yaml"
        else
            log_info "confirmed live (id=${vid:-unknown})"
            reset_state
            write_state "$state_path"
            exit 0
        fi
    else
        # Confirmed not live: yt-dlp successfully extracted info for
        # whatever the /live URL currently resolves to, and it says not
        # live - this is "YouTube reachable and answering that no
        # broadcast is live" (FR7c outcome (b)), as distinct from
        # extraction failing outright (c) above.
        not_live_reason="not live"
        log_warn "confirmed NOT live (id=${vid:-unknown})"
    fi

    # The backoff gate only suppresses further *action* once escalation has
    # already been triggered once - it must never suppress the observation
    # above, or a real recovery happening during a backoff window would go
    # unnoticed until the entire window elapsed instead of on the very next
    # poll.
    if (( next_action_at > 0 && now < next_action_at )); then
        log_info "still ${not_live_reason}; backing off, $(( next_action_at - now ))s remaining before next action (current_backoff=${current_backoff_seconds}s)"
        exit 0
    fi

    consecutive_not_live=$(( consecutive_not_live + 1 ))

    local max_before_escalation backoff_ceiling poll_interval
    max_before_escalation=$(cfg '.external_check.max_restarts_before_escalation' 3)
    backoff_ceiling=$(cfg '.external_check.backoff_ceiling_seconds' 1800)
    poll_interval=$(cfg '.external_check.poll_interval_seconds' 180)

    if (( consecutive_not_live < max_before_escalation )); then
        log_event EXTERNAL_RESTART "restarting $PIGEONCAM_STREAM_UNIT (${not_live_reason}, attempt ${consecutive_not_live}/${max_before_escalation})"
        systemctl restart "$PIGEONCAM_STREAM_UNIT"
        current_backoff_seconds=0
        next_action_at=0
    else
        attempt_escalation "$not_live_reason"
        if (( current_backoff_seconds == 0 )); then
            current_backoff_seconds=$poll_interval
        else
            current_backoff_seconds=$(( current_backoff_seconds * 2 ))
            (( current_backoff_seconds > backoff_ceiling )) && current_backoff_seconds=$backoff_ceiling
        fi
        next_action_at=$(( now + current_backoff_seconds ))
        log_event ESCALATION_BACKOFF "next escalation attempt in ${current_backoff_seconds}s (ceiling ${backoff_ceiling}s)"
    fi

    # Whatever action was just taken above (restart or escalation), the old
    # frame-hash baseline is now stale regardless of which reason triggered
    # it - a fresh ffmpeg process and possibly a fresh broadcast means the
    # next sample should start tracking from scratch, not compare against
    # pre-restart content.
    reset_freeze_state
    write_state "$state_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

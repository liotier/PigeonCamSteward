#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-archive-trim.sh - FR11: hourly retention pass over the local
# archive. Within the configured daytime window, trims each hour's segments
# (there may be several - restarts split hours into multiple files, FR10)
# down to daytime_keep_minutes total, oldest-first; outside the window,
# discards the hour's segments entirely, unless archive.nighttime_discard
# is set to false, in which case it's trimmed to the same daytime_keep_minutes
# budget instead of being discarded.
#
# Invoked hourly by systemd/pigeoncam-archive-trim.timer, shortly after each
# hour's segment(s) close.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-archive-trim"

# segment_duration_seconds <file> - integer-truncated duration via ffprobe;
# prints 0 (treated by the caller as "unknown, don't touch it") if ffprobe
# is unavailable or the probe fails.
segment_duration_seconds() {
    local f="$1" out
    if command -v ffprobe >/dev/null 2>&1; then
        out=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$f" 2>/dev/null || true)
        if [[ -n "$out" && "$out" != "N/A" ]]; then
            printf '%d' "${out%%.*}"
            return 0
        fi
    fi
    printf '0'
}

# hour_in_daytime <HH:MM> <start HH:MM> <end HH:MM> - fixed-width zero-
# padded HH:MM strings sort lexicographically the same as chronologically,
# so plain string comparison is sufficient; does not handle a window
# wrapping past midnight (not a configuration SPEC.md anticipates).
hour_in_daytime() {
    local hour="$1" start="$2" end="$3"
    [[ "$hour" > "$start" || "$hour" == "$start" ]] && [[ "$hour" < "$end" ]]
}

trim_file_to() {
    local file="$1" keep_seconds="$2" segment_format="$3" tmp
    tmp="${file}.trim.tmp"
    # -f is required here: the temp file's ".trim.tmp" suffix defeats
    # ffmpeg's usual extension-based format auto-detection (verified: it
    # refuses to guess and errors out), and explicitly naming the format
    # we already know from config is more robust than renaming around the
    # problem anyway.
    if ! ffmpeg -y -v error -i "$file" -t "$keep_seconds" -c copy -map 0 -f "$segment_format" "$tmp" </dev/null; then
        log_error "trim failed for $file, leaving it untouched"
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$file"
}

process_hour() {
    local hour_prefix="$1" hour_label="$2" segment_dir="$3" ext="$4" daytime_start="$5" daytime_end="$6" keep_minutes="$7" segment_format="$8" nighttime_discard="$9"

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$segment_dir" -maxdepth 1 -type f -name "${hour_prefix}*.${ext}" -print0 | sort -z)

    if (( ${#files[@]} == 0 )); then
        log_info "no segments found for hour ${hour_prefix} (nothing to do)"
        return 0
    fi

    local in_daytime=true
    if ! hour_in_daytime "$hour_label" "$daytime_start" "$daytime_end"; then
        in_daytime=false
        if [[ "$nighttime_discard" == "true" ]]; then
            log_info "hour ${hour_prefix} (${hour_label}) is outside daytime window [$daytime_start,$daytime_end) - discarding ${#files[@]} segment(s)"
            rm -f -- "${files[@]}"
            return 0
        fi
    fi

    local budget=$(( keep_minutes * 60 ))
    if $in_daytime; then
        log_info "hour ${hour_prefix} (${hour_label}) is in daytime window - trimming ${#files[@]} segment(s) to ${keep_minutes}m total, oldest-first"
    else
        log_info "hour ${hour_prefix} (${hour_label}) is outside daytime window but nighttime_discard is false - trimming ${#files[@]} segment(s) to ${keep_minutes}m total, oldest-first"
    fi

    local f dur
    for f in "${files[@]}"; do
        if (( budget <= 0 )); then
            log_info "budget exhausted - deleting $f"
            rm -f -- "$f"
            continue
        fi
        dur=$(segment_duration_seconds "$f")
        if (( dur <= 0 )); then
            log_warn "could not determine duration of $f, keeping it untouched and not counting it against the budget"
            continue
        fi
        if (( dur <= budget )); then
            budget=$(( budget - dur ))
        else
            log_info "trimming $f to ${budget}s (had ${dur}s)"
            trim_file_to "$f" "$budget" "$segment_format"
            budget=0
        fi
    done
}

main() {
    if ! cfg_bool '.archive.enabled' true; then
        log_info "archive.enabled is false, nothing to trim"
        exit 0
    fi

    local segment_dir segment_format daytime_start daytime_end keep_minutes ext
    segment_dir=$(cfg '.archive.segment_dir' /var/lib/pigeoncam/archive)
    segment_format=$(cfg '.archive.segment_format' mpegts)
    daytime_start=$(cfg '.archive.daytime_start' 04:00)
    daytime_end=$(cfg '.archive.daytime_end' 20:30)
    keep_minutes=$(cfg '.archive.daytime_keep_minutes' 60)
    ext=$(segment_ext_for_format "$segment_format")

    local nighttime_discard=false
    if cfg_bool '.archive.nighttime_discard' true; then
        nighttime_discard=true
    fi

    if [[ ! -d "$segment_dir" ]]; then
        log_warn "archive.segment_dir '$segment_dir' does not exist, nothing to trim"
        exit 0
    fi

    # Process "the hour that most recently closed": run shortly after the
    # top of the hour (the timer's normal schedule), so that's the
    # previous hour.
    local hour_prefix hour_label
    hour_prefix=$(date -d '1 hour ago' '+%Y%m%d_%H')
    hour_label=$(date -d '1 hour ago' '+%H:00')

    process_hour "$hour_prefix" "$hour_label" "$segment_dir" "$ext" "$daytime_start" "$daytime_end" "$keep_minutes" "$segment_format" "$nighttime_discard"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

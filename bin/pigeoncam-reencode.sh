#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-reencode.sh - FR13 (optional, off by default): batch re-encode
# already-closed archive segments to libx265 to shrink long-term storage.
# Explicitly a background job: runs at low CPU/IO priority (nice/ionice),
# documented as unsuitable for real-time use on older CPUs, and never
# invoked from the live path - only ever against closed segment files.
#
# Not wired to a timer by default (FR13 is off by default); run manually or
# add your own low-frequency systemd timer / cron entry if you enable it.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-reencode"

# current_video_codec / target_codec_name - used to skip files that are
# already in the target codec, so re-running this job doesn't repeatedly
# re-encode (and quality-degrade) files it already converted.
current_video_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 -- "$1" 2>/dev/null
}

target_codec_name() {
    case "$1" in
        libx265) printf 'hevc' ;;
        libx264) printf 'h264' ;;
        *) printf '' ;;
    esac
}

main() {
    if ! cfg_bool '.reencode.enabled' false; then
        log_info "reencode.enabled is false, nothing to do"
        exit 0
    fi
    require_cmd ffmpeg ffprobe nice ionice

    local segment_dir segment_format ext codec preset crf target_codec
    segment_dir=$(cfg '.archive.segment_dir' /var/lib/pigeoncam/archive)
    segment_format=$(cfg '.archive.segment_format' mpegts)
    ext=$(segment_ext_for_format "$segment_format")
    codec=$(cfg '.reencode.codec' libx265)
    preset=$(cfg '.reencode.preset' faster)
    crf=$(cfg '.reencode.crf' 26)
    target_codec=$(target_codec_name "$codec")

    if [[ ! -d "$segment_dir" ]]; then
        log_warn "archive.segment_dir '$segment_dir' does not exist, nothing to do"
        exit 0
    fi

    local -a files=()
    while IFS= read -r -d '' f; do
        [[ "$f" == *.trim.tmp ]] && continue
        files+=("$f")
    done < <(find "$segment_dir" -maxdepth 1 -type f -name "*.${ext}" -print0 | sort -z)

    if (( ${#files[@]} == 0 )); then
        log_info "no segments found under $segment_dir"
        exit 0
    fi

    log_info "checking ${#files[@]} segment(s) for re-encode with $codec preset=$preset crf=$crf (nice/ionice, background priority)"

    local f out cur
    for f in "${files[@]}"; do
        cur=$(current_video_codec "$f")
        if [[ -n "$target_codec" && "$cur" == "$target_codec" ]]; then
            log_info "skipping $f (already $target_codec)"
            continue
        fi
        out="${f}.reencode.tmp"
        log_info "re-encoding $f ($cur -> $codec)"
        if nice -n 19 ionice -c3 ffmpeg -y -v error -i "$f" \
            -c:v "$codec" -preset "$preset" -crf "$crf" -c:a copy \
            "$out" </dev/null; then
            mv -f -- "$out" "$f"
        else
            log_error "re-encode failed for $f, leaving original untouched"
            rm -f -- "$out"
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

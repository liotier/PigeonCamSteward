#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-stream.sh - renders and execs the ffmpeg command from config.yaml.
# FR1-FR5 (capture/encode/stream), FR9-FR10 (tee archive). Command shape
# per SPEC.md Appendix A; run via systemd/pigeoncam-stream.service so
# Restart=always (FR6) covers it.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-stream"

main() {
    require_cmd ffmpeg

    local device input_format resolution framerate thread_queue_size
    device=$(cfg '.camera.device' /dev/pigeoncam)
    input_format=$(cfg '.camera.input_format' mjpeg)
    resolution=$(cfg '.camera.resolution' 1920x1080)
    framerate=$(cfg '.camera.framerate' 30)
    thread_queue_size=$(cfg '.camera.thread_queue_size' 512)

    local preset tune bitrate maxrate bufsize
    preset=$(cfg '.encode.preset' veryfast)
    tune=$(cfg '.encode.tune' "")
    bitrate=$(cfg '.encode.bitrate_kbps' 6000)
    maxrate=$(cfg '.encode.maxrate_kbps' 6000)
    bufsize=$(cfg '.encode.bufsize_kbps' 12000)

    local audio_mode amplitude sample_rate real_source real_source_user audio_bitrate
    audio_mode=$(cfg '.audio.mode' synthetic)
    amplitude=$(cfg '.audio.synthetic_amplitude' 0.001)
    sample_rate=$(cfg '.audio.sample_rate' 48000)
    real_source=$(cfg '.audio.real_source' "")
    real_source_user=$(cfg '.audio.real_source_user' "")
    audio_bitrate=$(cfg '.audio.bitrate_kbps' 128)

    local ingest_url key_file yt_key
    ingest_url=$(cfg '.youtube.ingest_url')
    key_file=$(cfg '.youtube.stream_key_file')
    if [[ -z "$ingest_url" ]]; then
        log_error "youtube.ingest_url is not set"
        exit 1
    fi
    if [[ ! -f "$key_file" ]]; then
        log_error "stream key file not found: $key_file"
        exit 1
    fi
    yt_key=$(<"$key_file")
    yt_key="${yt_key//[$'\t\r\n ']/}"   # defensive trim of accidental whitespace/newline
    if [[ -z "$yt_key" ]]; then
        log_error "stream key file is empty: $key_file"
        exit 1
    fi

    local archive_enabled=false segment_dir segment_length segment_format
    if cfg_bool '.archive.enabled' true; then
        archive_enabled=true
    fi
    segment_dir=$(cfg '.archive.segment_dir' /var/lib/pigeoncam/archive)
    segment_length=$(cfg '.archive.segment_length_seconds' 3600)
    segment_format=$(cfg '.archive.segment_format' mpegts)

    local progress_file
    progress_file=$(cfg '.watchdog.progress_file' /run/pigeoncam/progress)

    # --- bookkeeping: progress file reset, start marker -----------------
    mkdir -p -- "$(dirname -- "$progress_file")"
    # ffmpeg opens -progress for append and never truncates it, even across
    # separate process invocations (verified empirically). Reset it on every
    # start so it doesn't grow unbounded across a multi-week run's worth of
    # watchdog/rotation restarts; within a single run it still grows
    # continuously, which watchdog/status-check handle by reading from the
    # end (lib: progress_last_frame/progress_age_seconds).
    : > "$progress_file"
    write_epoch_marker "$(marker_path started_at)"

    if $archive_enabled; then
        if ! mkdir -p -- "$segment_dir" 2>/dev/null || [[ ! -w "$segment_dir" ]]; then
            log_error "archive.segment_dir '$segment_dir' does not exist or is not writable; run pigeoncam-doctor.sh"
            exit 1
        fi
    fi

    # --- build ffmpeg argv (Appendix A) ----------------------------------
    local -a args=()
    args+=(-thread_queue_size "$thread_queue_size" -f v4l2 -input_format "$input_format"
           -video_size "$resolution" -framerate "$framerate" -i "$device")

    local have_audio=true
    case "$audio_mode" in
        synthetic)
            args+=(-f lavfi -i "anoisesrc=color=white:amplitude=${amplitude}:sample_rate=${sample_rate}")
            ;;
        real)
            if [[ -z "$real_source" ]]; then
                log_error "audio.mode is 'real' but audio.real_source is empty - see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md 'Real audio mode' for how to find and configure it"
                exit 1
            fi
            if [[ -n "$real_source_user" ]] && ! resolve_pulse_bridge_env "$real_source_user"; then
                log_error "audio.real_source_user '$real_source_user' has no active PipeWire/PulseAudio session - does the user exist? is it running? (loginctl enable-linger $real_source_user keeps one alive without an interactive login; see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md 'Real audio mode' for the full picture)"
                exit 1
            fi
            # Pulse/PipeWire by source name, never a raw hw:/plughw: node -
            # the desktop audio server already holds the device open
            # exclusively (SPEC.md §6a audio table). This service runs as
            # root (FR6), which has no PipeWire/PulseAudio session of its
            # own; if real_source lives in a different user's session (the
            # normal case), audio.real_source_user bridges to it via
            # PULSE_SERVER/PULSE_COOKIE (resolve_pulse_bridge_env, above)
            # instead of connecting to root's own nonexistent one.
            args+=(-f pulse -i "$real_source")
            ;;
        off)
            have_audio=false
            log_warn "audio.mode=off: no audio track will be sent. Not recommended - see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md '\"Preparing stream\" hang with no ffmpeg error' (silent/absent audio is the most common cause)."
            ;;
        *)
            log_error "unknown audio.mode: $audio_mode (expected synthetic|real|off)"
            exit 1
            ;;
    esac

    if $have_audio; then
        args+=(-map 0:v -map 1:a)
    else
        args+=(-map 0:v)
    fi

    args+=(-c:v libx264 -preset "$preset")
    [[ -n "$tune" ]] && args+=(-tune "$tune")
    args+=(-b:v "${bitrate}k" -maxrate "${maxrate}k" -bufsize "${bufsize}k")
    args+=(-pix_fmt yuv420p -g "$(( framerate * 2 ))" -keyint_min "$(( framerate * 2 ))")

    if $have_audio; then
        args+=(-c:a aac -b:a "${audio_bitrate}k" -ar "$sample_rate")
    fi

    args+=(-progress "$progress_file")

    # The stream key is interpolated here, never written into the unit file
    # or this script's own source, and excluded from git via .gitignore. It
    # will still appear in this ffmpeg process's own argv/`ps` output once
    # exec'd - unavoidable, since the destination URL is necessarily an
    # ffmpeg argument - but a YouTube stream key is a disposable,
    # Studio-revocable credential (SPEC.md §3), not a secret worth
    # contorting the architecture to hide from `ps`.
    local rtmps_url="${ingest_url%/}/${yt_key}"

    if $archive_enabled; then
        local ext strftime_pattern tee_spec
        ext=$(segment_ext_for_format "$segment_format")
        strftime_pattern="${segment_dir%/}/%Y%m%d_%H%M%S.${ext}"
        # segment_atclocktime=1 is a deliberate departure from the literal
        # Appendix A command shape: without it, segment cuts float relative
        # to whenever ffmpeg happened to start, not to wall-clock hours, and
        # FR11's "select this hour by filename prefix" / daytime-window
        # logic only holds together if segments are actually cut at clock
        # boundaries. Confirmed empirically that cuts land within about one
        # GOP (2s) of the true boundary, immaterial for hourly bucketing.
        tee_spec="[f=flv:onfail=abort]${rtmps_url}|[f=segment:segment_time=${segment_length}:segment_format=${segment_format}:segment_atclocktime=1:strftime=1:reset_timestamps=1:onfail=ignore]${strftime_pattern}"
        args+=(-f tee -use_fifo 1 "$tee_spec")
    else
        args+=(-f flv "$rtmps_url")
    fi

    log_info "starting ffmpeg: device=$device resolution=$resolution fps=$framerate audio=$audio_mode archive=$archive_enabled"
    exec ffmpeg "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

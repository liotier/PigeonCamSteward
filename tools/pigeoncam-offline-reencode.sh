#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-offline-reencode.sh - standalone batch re-encode for archive
# segment files, meant to run on a DIFFERENT, stronger-CPU host than the
# pigeon-cam itself - e.g. against the archive directory mounted over
# NFS/SMB/sshfs. Deliberately independent of lib/pigeoncam-common.sh and
# config.yaml (unlike bin/pigeoncam-reencode.sh, the on-host equivalent,
# which runs nice/ionice-throttled alongside the live stream on the same
# CPU-limited host that can't spare cycles for it): this script assumes
# it has the whole machine to itself, takes its target directory as an
# argument instead of reading archive.segment_dir, and needs nothing
# installed beyond ffmpeg/ffprobe - no project checkout required on the
# host that runs it.
#
# Safe to interrupt and re-run: writes each output to a .reencode.tmp
# file next to the original and only replaces it once ffmpeg exits 0,
# and skips any file whose video stream is already in the target codec -
# checked with ffprobe against the file's actual encoded content, not
# its filename or extension - so a second pass over the same directory
# only touches whatever the first pass didn't finish or hadn't reached
# yet, and never re-encodes (and quality-degrades) the same file twice.

set -euo pipefail

CODEC="libx265"
PRESET="faster"
CRF="26"
EXT="ts"
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <directory>

Batch re-encodes archive segment files in <directory> to a smaller codec,
skipping any already in the target codec. Meant to run on a separate,
stronger-CPU host against the archive directory mounted from the
pigeon-cam host - not part of the on-host deployment, no config.yaml or
project checkout required, just ffmpeg/ffprobe.

  --codec CODEC    ffmpeg video codec (default: $CODEC)
  --preset PRESET  ffmpeg preset (default: $PRESET)
  --crf CRF        constant rate factor, lower = larger file/better quality (default: $CRF)
  --ext EXT        file extension to process, without the dot (default: $EXT) -
                    match archive.segment_format from the pigeon-cam's own
                    config.yaml: mpegts -> ts, mp4 -> mp4, matroska/mkv -> mkv
  --dry-run        list what would be re-encoded/skipped, change nothing
  -h, --help       show this help
EOF
}

# current_video_codec / target_codec_name - same check bin/pigeoncam-reencode.sh
# uses on-host, deliberately duplicated rather than shared: that script's
# helpers live in lib/pigeoncam-common.sh, sourcing it here would pull in
# config.yaml/PIGEONCAM_CONFIG machinery this standalone tool has no use
# for and shouldn't need installed.
current_video_codec() {
    # head -1: MPEG-TS (ext=ts, this project's default archive format)
    # reports the same stream twice - once nested under [PROGRAM], once
    # flat - so this would otherwise return two identical lines instead
    # of one value, breaking the "already re-encoded" string comparison
    # below on every single invocation (caught directly against a real
    # generated .ts file). Harmless no-op against formats that don't have
    # this duplication.
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 -- "$1" 2>/dev/null | head -1
}

target_codec_name() {
    case "$1" in
        libx265) printf 'hevc' ;;
        libx264) printf 'h264' ;;
        *) printf '' ;;
    esac
}

# segment_age_seconds <file> - seconds since last modified, or a very
# large number if unreadable. Used to skip a segment that's still being
# actively written (continuously-fresh mtime) rather than grab it
# mid-write and truncate whatever ffmpeg writes to it afterward - this
# tool is explicitly meant to run against a mounted, currently-live
# archive directory (see the header comment), so this matters here.
segment_age_seconds() {
    local mtime now
    mtime=$(stat -c '%Y' -- "$1" 2>/dev/null) || { printf '999999999'; return; }
    now=$(date +%s)
    printf '%d' "$(( now - mtime ))"
}

# ext_to_ffmpeg_format - ffmpeg's -f muxer name for --ext, needed because
# the temp output file ends in .reencode.tmp, not .ts/.mp4/.mkv: ffmpeg
# infers the container from the output filename's extension by default,
# and fails to choose a muxer at all against a .reencode.tmp name (caught
# directly - the first real run of this script hit exactly this).
ext_to_ffmpeg_format() {
    case "$1" in
        ts) printf 'mpegts' ;;
        mkv) printf 'matroska' ;;
        *) printf '%s' "$1" ;;
    esac
}

main() {
    local dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --codec) CODEC="$2"; shift 2 ;;
            --preset) PRESET="$2"; shift 2 ;;
            --crf) CRF="$2"; shift 2 ;;
            --ext) EXT="$2"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
            *) dir="$1"; shift ;;
        esac
    done

    if [[ -z "$dir" ]]; then
        echo "error: no directory given" >&2
        usage >&2
        exit 2
    fi
    if [[ ! -d "$dir" ]]; then
        echo "error: '$dir' is not a directory" >&2
        exit 1
    fi
    local cmd
    for cmd in ffmpeg ffprobe; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found in PATH" >&2; exit 1; }
    done

    local target_codec
    target_codec=$(target_codec_name "$CODEC")

    # A .reencode.tmp temp file can never match "*.${EXT}" below (it
    # doesn't end in .ts/.mp4/.mkv) so no explicit filter is needed - find's
    # own -name pattern already excludes it structurally.
    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "*.${EXT}" -print0 | sort -z)

    if (( ${#files[@]} == 0 )); then
        echo "no .${EXT} files found under $dir"
        exit 0
    fi

    echo "checking ${#files[@]} file(s) under $dir for re-encode with $CODEC preset=$PRESET crf=$CRF"
    $DRY_RUN && echo "(--dry-run: not changing anything)"

    local f out cur age reencoded=0 skipped_encoded=0 skipped_fresh=0 failed=0
    for f in "${files[@]}"; do
        age=$(segment_age_seconds "$f")
        if (( age < 120 )); then
            echo "skip     $f (modified ${age}s ago - likely still being written)"
            skipped_fresh=$(( skipped_fresh + 1 ))
            continue
        fi
        cur=$(current_video_codec "$f")
        if [[ -n "$target_codec" && "$cur" == "$target_codec" ]]; then
            echo "skip     $f (already $target_codec)"
            skipped_encoded=$(( skipped_encoded + 1 ))
            continue
        fi
        if $DRY_RUN; then
            echo "would reencode $f ($cur -> $CODEC)"
            continue
        fi
        out="${f}.reencode.tmp"
        echo "reencode $f ($cur -> $CODEC) ..."
        if ffmpeg -y -v error -i "$f" -c:v "$CODEC" -preset "$PRESET" -crf "$CRF" -c:a copy \
            -f "$(ext_to_ffmpeg_format "$EXT")" "$out" </dev/null; then
            mv -f -- "$out" "$f"
            reencoded=$(( reencoded + 1 ))
        else
            echo "FAILED:  $f, leaving original untouched" >&2
            rm -f -- "$out"
            failed=$(( failed + 1 ))
        fi
    done

    echo "done: $reencoded re-encoded, $skipped_encoded already $CODEC, $skipped_fresh in progress, $failed failed"
    (( failed == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

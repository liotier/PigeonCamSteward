#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-doctor.sh - FR17: environment validation, run before first use.
# Every check runs independently (not stopped at the first failure) so one
# invocation surfaces the full list of problems, except for a missing
# config file or config parser, which are hard prerequisites for every
# other check and are reported alone rather than cascading into crashes.

set -uo pipefail   # deliberately no -e: individual checks are allowed to fail; we keep going and aggregate

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-doctor"

UNIT_FILE_OVERRIDE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--config PATH] [--unit-file PATH]

Validates the environment PigeonCamSteward needs before first use.
  --config PATH      config.yaml to validate (default: \$PIGEONCAM_CONFIG or /etc/pigeoncam/config.yaml)
  --unit-file PATH   pigeoncam-stream.service to check for the systemd
                     restart-limit setting (default: /etc/systemd/system/pigeoncam-stream.service)
EOF
}

PASS=0
FAIL=0
WARN=0

result() {
    local status="$1" name="$2" detail="$3"
    case "$status" in
        PASS) PASS=$((PASS+1)); printf 'PASS  %-40s %s\n' "$name" "$detail" ;;
        FAIL) FAIL=$((FAIL+1)); printf 'FAIL  %-40s %s\n' "$name" "$detail" ;;
        WARN) WARN=$((WARN+1)); printf 'WARN  %-40s %s\n' "$name" "$detail" ;;
    esac
}

print_summary() {
    echo ""
    echo "-- ${PASS} passed, ${WARN} warning(s), ${FAIL} failed --"
}

# --- helpers ---------------------------------------------------------------

map_input_format_to_fourcc() {
    case "$1" in
        mjpeg) printf 'MJPG' ;;
        yuyv)  printf 'YUYV' ;;
        h264)  printf 'H264' ;;
        *)     printf '%s' "${1^^}" ;;
    esac
}

# camera_mode_available <device> <FOURCC> <WxH> <fps> - parses
# `v4l2-ctl --list-formats-ext -d <device>` looking for an exact
# format+resolution+framerate combination. Pure bash (no gawk-only 3-arg
# match()), so it doesn't care whether the system's /usr/bin/awk is mawk or
# gawk.
camera_mode_available() {
    local device="$1" want_fmt="$2" want_res="$3" want_fps="$4"
    local cur_fmt="" cur_res="" line fps
    while IFS= read -r line; do
        if [[ "$line" =~ \[[0-9]+\]:\ \'([A-Za-z0-9]+)\' ]]; then
            cur_fmt="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Size:\ Discrete\ ([0-9]+x[0-9]+) ]]; then
            cur_res="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ Interval:\ Discrete\ .*\(([0-9.]+)\ fps\) ]]; then
            fps="${BASH_REMATCH[1]}"
            if [[ "$cur_fmt" == "$want_fmt" && "$cur_res" == "$want_res" && "${fps%%.*}" == "$want_fps" ]]; then
                return 0
            fi
        fi
    done < <(v4l2-ctl --list-formats-ext -d "$device" 2>/dev/null)
    return 1
}

# --- checks ------------------------------------------------------------

check_yq() {
    if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        result PASS "config parser (yq/jq)" "both present"
    else
        result FAIL "config parser (yq/jq)" "yq and/or jq missing - every pigeoncam-*.sh script needs both (apt install yq jq)"
    fi
}

check_camera_mode() {
    local device fourcc resolution framerate
    device=$(cfg '.camera.device' /dev/pigeoncam)
    resolution=$(cfg '.camera.resolution' 1920x1080)
    framerate=$(cfg '.camera.framerate' 30)
    fourcc=$(map_input_format_to_fourcc "$(cfg '.camera.input_format' mjpeg)")

    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        result FAIL "camera mode (v4l2-ctl)" "v4l2-ctl not installed (apt install v4l-utils)"
        return
    fi
    if [[ ! -e "$device" ]]; then
        result FAIL "camera mode ($device)" "device does not exist - see $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 2 for the udev symlink setup, or check camera.device in $PIGEONCAM_CONFIG"
        return
    fi
    if camera_mode_available "$device" "$fourcc" "$resolution" "$framerate"; then
        result PASS "camera mode ($device)" "$fourcc $resolution @ ${framerate}fps available"
    else
        result FAIL "camera mode ($device)" "$fourcc $resolution @ ${framerate}fps NOT offered by this device - check 'v4l2-ctl --list-formats-ext -d $device' (common trap: YUYV-only at this resolution/fps, see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md 'MJPEG vs YUYV at high resolution/frame rate')"
    fi
}

check_ffmpeg_build() {
    if ! command -v ffmpeg >/dev/null 2>&1; then
        result FAIL "ffmpeg build" "ffmpeg not installed"
        return
    fi
    local conf
    conf=$(ffmpeg -version 2>/dev/null | grep -m1 '^configuration:')
    local ok_x264=false ok_tls=false
    [[ "$conf" == *"--enable-libx264"* ]] && ok_x264=true
    [[ "$conf" == *"--enable-gnutls"* || "$conf" == *"--enable-openssl"* ]] && ok_tls=true
    if $ok_x264 && $ok_tls; then
        result PASS "ffmpeg build" "libx264 + TLS (RTMPS) support present"
    else
        local -a missing=()
        $ok_x264 || missing+=("libx264")
        $ok_tls || missing+=("gnutls/openssl (RTMPS)")
        result FAIL "ffmpeg build" "missing: ${missing[*]} - install an ffmpeg build with both (the stock 'apt install ffmpeg' on current Debian/Ubuntu already has both; a custom/minimal build may not)"
    fi
}

check_stream_key() {
    local key_file
    key_file=$(cfg '.youtube.stream_key_file' /etc/pigeoncam/stream_key)
    if [[ ! -f "$key_file" ]]; then
        result FAIL "stream key file" "$key_file does not exist - see $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 3 to create it"
        return
    fi
    local mode
    mode=$(stat -c '%a' -- "$key_file" 2>/dev/null)
    if [[ "$mode" == "600" ]]; then
        result PASS "stream key file" "$key_file exists, mode 600"
    else
        result FAIL "stream key file" "$key_file has mode ${mode:-unknown}, expected 600 (chmod 600 $key_file)"
    fi
}

check_udev_rule() {
    local device symlink_name
    device=$(cfg '.camera.device' /dev/pigeoncam)
    symlink_name=$(basename -- "$device")
    # PIGEONCAM_DOCTOR_UDEV_DIRS (colon-separated) overrides the real system
    # search path - used by the test suite to point this check at fixture
    # directories instead of mutating /etc/udev/rules.d.
    local -a rule_dirs=()
    if [[ -n "${PIGEONCAM_DOCTOR_UDEV_DIRS:-}" ]]; then
        IFS=':' read -ra rule_dirs <<< "$PIGEONCAM_DOCTOR_UDEV_DIRS"
    else
        rule_dirs=(/etc/udev/rules.d /run/udev/rules.d /usr/lib/udev/rules.d /lib/udev/rules.d)
    fi
    local d
    for d in "${rule_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        if grep -RIlq "SYMLINK+=\"${symlink_name}\"" "$d" 2>/dev/null \
            || grep -RIlq "SYMLINK=\"${symlink_name}\"" "$d" 2>/dev/null; then
            result PASS "udev rule" "found a rule creating $device under $d"
            return
        fi
    done
    result FAIL "udev rule" "no udev rule found creating symlink '$symlink_name' - see $PIGEONCAM_PROJECT_ROOT/udev/99-pigeoncam.rules.example, or $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 2 for the full walkthrough"
}

check_real_audio() {
    local mode
    mode=$(cfg '.audio.mode' synthetic)
    if [[ "$mode" != "real" ]]; then
        result PASS "audio device" "mode=$mode, no Pulse/PipeWire source check needed"
        return
    fi
    local src
    src=$(cfg '.audio.real_source' "")
    if [[ -z "$src" ]]; then
        result FAIL "audio device" "audio.mode is 'real' but audio.real_source is empty - see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md 'Real audio mode' for how to find and configure it"
        return
    fi
    if ! command -v pactl >/dev/null 2>&1; then
        result FAIL "audio device" "pactl not found (need PipeWire-pulse or PulseAudio)"
        return
    fi
    local real_source_user
    real_source_user=$(cfg '.audio.real_source_user' "")
    if [[ -n "$real_source_user" ]] && ! resolve_pulse_bridge_env "$real_source_user"; then
        result FAIL "audio device" "audio.real_source_user '$real_source_user' has no active PipeWire/PulseAudio session - does the user exist? is it running? (loginctl enable-linger $real_source_user; see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md 'Real audio mode' for the full picture)"
        return
    fi
    # Captured first, not piped straight to `grep -q`: under this script's
    # own pipefail, grep -q's early exit on a match can SIGPIPE pactl
    # before it finishes writing, which pipefail then reports as failure
    # even when grep found exactly what it was looking for. Unlikely in
    # practice for a short source list, but the same fragile pattern that
    # reliably broke a much larger `ffmpeg -encoders` listing elsewhere
    # (tests/test_offline_reencode.sh) - fixed here too while auditing
    # for it.
    local pactl_sources
    pactl_sources=$(pactl list sources short 2>/dev/null)
    if grep -q -- "$src" <<<"$pactl_sources"; then
        result PASS "audio device" "source '$src' is enumerable${real_source_user:+ (bridged via $real_source_user)}"
    else
        result FAIL "audio device" "source '$src' not found in 'pactl list sources short'${real_source_user:+ (checked via bridged user $real_source_user)} - see $PIGEONCAM_PROJECT_ROOT/docs/TROUBLESHOOTING.md 'Real audio mode'"
    fi
}

check_external_check_tooling() {
    if ! cfg_bool '.external_check.enabled' true; then
        result PASS "external check tooling" "external_check.enabled=false, skipped"
        return
    fi
    local method
    method=$(cfg '.external_check.method' yt-dlp)
    if [[ "$method" != "yt-dlp" ]]; then
        result FAIL "external check tooling" "external_check.method '$method' is not implemented (only 'yt-dlp' is) - every poll will be treated as indeterminate until this is set back to yt-dlp"
        return
    fi
    local ok=true
    if ! command -v yt-dlp >/dev/null 2>&1; then
        result FAIL "external check tooling" "yt-dlp not installed (see $PIGEONCAM_PROJECT_ROOT/README.md quickstart step 1 for the standalone-binary install - do NOT use apt or pip, see $PIGEONCAM_PROJECT_ROOT/SPEC.md §6a)"
        ok=false
    fi
    if ! command -v jq >/dev/null 2>&1; then
        result FAIL "external check tooling" "jq not installed"
        ok=false
    fi
    $ok || return

    local url
    url=$(cfg '.external_check.channel_live_url' "")
    if [[ -z "$url" || "$url" == *"YOUR_HANDLE"* ]]; then
        result WARN "external check tooling" "external_check.channel_live_url is not configured yet"
        return
    fi
    local json
    if json=$(timeout 30 yt-dlp -j --no-warnings --no-playlist "$url" 2>/dev/null) && [[ -n "$json" ]]; then
        result PASS "external check tooling" "yt-dlp extracted $url successfully just now"
    else
        result WARN "external check tooling" "yt-dlp could NOT extract $url right now (may just mean not currently live; a version check alone wouldn't catch a real extractor break, so this is a live probe, not a static check)"
    fi
}

check_archive_dir() {
    if ! cfg_bool '.archive.enabled' true; then
        result PASS "archive directory" "archive.enabled=false, skipped"
        return
    fi
    local dir
    dir=$(cfg '.archive.segment_dir' /var/lib/pigeoncam/archive)
    mkdir -p -- "$dir" 2>/dev/null
    local probe="$dir/.pigeoncam-doctor-write-test.$$"
    if ( : > "$probe" ) 2>/dev/null; then
        rm -f -- "$probe"
        result PASS "archive directory" "$dir exists and is writable"
    else
        result FAIL "archive directory" "$dir does not exist or is not writable (mkdir -p was already attempted) - check permissions on its parent directory"
    fi
}

check_tier2() {
    if ! cfg_bool '.tier2.enabled' false; then
        result PASS "Tier 2 (YouTube API rotation)" "tier2.enabled=false, skipped"
        return
    fi
    if ! tier2_available; then
        result FAIL "Tier 2 (YouTube API rotation)" "tier2.enabled=true but no venv at $PIGEONCAM_PROJECT_ROOT/api/venv/ - see $PIGEONCAM_PROJECT_ROOT/docs/TIER2.md (sudo apt install -y python3-venv && python3 -m venv $PIGEONCAM_PROJECT_ROOT/api/venv && $PIGEONCAM_PROJECT_ROOT/api/venv/bin/pip install -r $PIGEONCAM_PROJECT_ROOT/api/requirements.txt)"
        return
    fi

    local venv_python
    venv_python=$(tier2_venv_python)
    if ! "$venv_python" -c "import googleapiclient.discovery, google.oauth2.credentials, google_auth_oauthlib.flow, yaml" >/dev/null 2>&1; then
        result FAIL "Tier 2 (YouTube API rotation)" "$PIGEONCAM_PROJECT_ROOT/api/venv/ exists but its dependencies don't import cleanly - re-run: $PIGEONCAM_PROJECT_ROOT/api/venv/bin/pip install -r $PIGEONCAM_PROJECT_ROOT/api/requirements.txt"
        return
    fi

    local client_secret token_file stream_id ok=true mode
    client_secret=$(cfg '.tier2.client_secret_file' "")
    token_file=$(cfg '.tier2.token_file' "")
    stream_id=$(cfg '.tier2.persistent_stream_id' "")

    if [[ -z "$client_secret" || ! -f "$client_secret" ]]; then
        result FAIL "Tier 2 (YouTube API rotation)" "tier2.client_secret_file '$client_secret' does not exist - download it from Google Cloud Console, see $PIGEONCAM_PROJECT_ROOT/docs/TIER2.md"
        ok=false
    fi
    if [[ -z "$token_file" || ! -f "$token_file" ]]; then
        result FAIL "Tier 2 (YouTube API rotation)" "tier2.token_file '$token_file' does not exist - run: $venv_python $(tier2_script_path) --authorize"
        ok=false
    elif [[ "$(stat -c '%a' -- "$token_file" 2>/dev/null)" != "600" ]]; then
        result FAIL "Tier 2 (YouTube API rotation)" "tier2.token_file '$token_file' is not mode 600"
        ok=false
    fi
    if [[ -z "$stream_id" ]]; then
        result FAIL "Tier 2 (YouTube API rotation)" "tier2.persistent_stream_id is not set"
        ok=false
    fi
    $ok && result PASS "Tier 2 (YouTube API rotation)" "venv, dependencies, credentials, and persistent_stream_id all present"

    mode=$(cfg '.youtube.rotation.mode' restart)
    if [[ "$mode" != "api" ]]; then
        result WARN "Tier 2 (YouTube API rotation)" "tier2.enabled=true but youtube.rotation.mode is '$mode', not 'api' - Tier 2 will only be used for last-resort stuck-broadcast recovery, not routine rotation. This may be intentional."
    fi
}

check_start_limit() {
    local unit_file="${UNIT_FILE_OVERRIDE:-/etc/systemd/system/pigeoncam-stream.service}"
    if [[ ! -f "$unit_file" ]]; then
        result WARN "systemd start-limit" "$unit_file not installed yet - nothing to check (see $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 5, 'Install and start the systemd units')"
        return
    fi
    if grep -Eq '^[[:space:]]*StartLimitIntervalSec[[:space:]]*=[[:space:]]*0[[:space:]]*$' "$unit_file"; then
        result PASS "systemd start-limit" "StartLimitIntervalSec=0 present in $unit_file"
    else
        result FAIL "systemd start-limit" "$unit_file does not set StartLimitIntervalSec=0 - a burst of failures (e.g. camera unplugged) will permanently stop restarts. Add it under [Unit] (see $PIGEONCAM_PROJECT_ROOT/systemd/pigeoncam-stream.service for the shipped reference), then sudo systemctl daemon-reload"
    fi
}

# check_units_enabled - B1: the unit *file* being present and correctly
# written (check_start_limit, check_camera_mode, etc.) doesn't mean it's
# actually wired up - a copied-but-never-enabled unit is inert and silent
# until the next reboot or a manual start, which is exactly the kind of gap
# this whole project exists to catch before it costs a missed stream. Every
# unit in the README Quickstart's `enable --now` list is checked the same
# way regardless of which optional features are toggled on: each script
# already no-ops cleanly on its own disabled-feature config check (see e.g.
# pigeoncam-archive-trim.sh/pigeoncam-status-check.sh's main()), so having
# its timer enabled-but-idle is cheap and expected, not a problem to warn
# about separately.
check_units_enabled() {
    if ! command -v systemctl >/dev/null 2>&1; then
        result WARN "systemd units" "systemctl not found - skipping (not running under systemd?)"
        return
    fi
    local -a units=(
        pigeoncam-stream.service
        pigeoncam-watchdog.timer
        pigeoncam-status-check.timer
        pigeoncam-rotate.timer
        pigeoncam-archive-trim.timer
        pigeoncam-ytdlp-update.timer
    )
    local u state
    for u in "${units[@]}"; do
        state=$(systemctl is-enabled "$u" 2>/dev/null || true)
        case "$state" in
            enabled|static)
                result PASS "systemd unit ($u)" "enabled"
                ;;
            disabled)
                result FAIL "systemd unit ($u)" "installed but not enabled - sudo systemctl enable --now $u (see $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 5)"
                ;;
            masked)
                result FAIL "systemd unit ($u)" "masked - sudo systemctl unmask $u, then enable --now it"
                ;;
            *)
                result WARN "systemd unit ($u)" "not installed yet - see $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 5 to install and enable the systemd units"
                ;;
        esac
    done
}

# show_sizing_estimate - FR12: the project deliberately does not
# auto-compute or enforce a storage budget (drive sizes vary too much to
# hardcode), but the doctor script and README must show the sizing
# formula so users can size their own storage before committing to a
# retention window. Informational only, not a PASS/FAIL check.
show_sizing_estimate() {
    if ! cfg_bool '.archive.enabled' true; then
        return
    fi
    local bitrate_kbps daytime_start daytime_end keep_minutes
    bitrate_kbps=$(cfg '.encode.bitrate_kbps' 6000)
    daytime_start=$(cfg '.archive.daytime_start' 04:00)
    daytime_end=$(cfg '.archive.daytime_end' 20:30)
    keep_minutes=$(cfg '.archive.daytime_keep_minutes' 60)

    echo ""
    echo "Sizing estimate - not enforced, just a reference point:"
    echo "  storage = bitrate x retained-seconds-per-day x total-days"

    # 10# forces decimal interpretation - without it, bash arithmetic
    # treats a leading-zero hour/minute like "08" or "09" as an invalid
    # octal literal and errors out.
    local start_min end_min
    start_min=$(( 10#${daytime_start%%:*} * 60 + 10#${daytime_start##*:} ))
    end_min=$(( 10#${daytime_end%%:*} * 60 + 10#${daytime_end##*:} ))
    if (( end_min <= start_min )); then
        echo "  (could not parse daytime_start/daytime_end as a same-day HH:MM window - skipping the numeric example)"
        return
    fi
    awk -v kbps="$bitrate_kbps" -v win="$(( end_min - start_min ))" -v keep="$keep_minutes" '
        BEGIN {
            retained_sec_per_day = win * keep
            bytes_per_day = (kbps * 1000 / 8) * retained_sec_per_day
            gb_per_day = bytes_per_day / 1e9
            printf "  current config: %skbit/s, daytime window kept at %s min/hour -> ~%.2f GB/day (~%.1f GB/30d, ~%.1f GB/90d)\n", kbps, keep, gb_per_day, gb_per_day*30, gb_per_day*90
        }
    '
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) PIGEONCAM_CONFIG="$2"; shift 2 ;;
            --unit-file) UNIT_FILE_OVERRIDE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
    done

    if [[ ! -f "$PIGEONCAM_CONFIG" ]]; then
        result FAIL "config file" "$PIGEONCAM_CONFIG not found - copy $PIGEONCAM_PROJECT_ROOT/config.example.yaml first"
        print_summary
        exit 1
    fi

    # yq/jq are a hard prerequisite for every other check (they all call
    # cfg()); report alone and stop rather than cascading into a crash.
    check_yq
    if (( FAIL > 0 )); then
        print_summary
        exit 1
    fi

    check_camera_mode
    check_ffmpeg_build
    check_stream_key
    check_udev_rule
    check_real_audio
    check_external_check_tooling
    check_archive_dir
    check_tier2
    check_start_limit
    check_units_enabled

    show_sizing_estimate
    print_summary
    (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

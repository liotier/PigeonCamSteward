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

# daily_archive_gb - FR12's sizing formula (bitrate x retained-seconds-
# per-day), GB/day alone with no formatting - shared between
# show_sizing_estimate's printed reference and check_archive_disk_space's
# free-space comparison so the formula lives in exactly one place. Fails
# (empty stdout) rather than printing 0 if daytime_start/daytime_end can't
# be parsed as a same-day HH:MM window - the caller decides how to handle
# "unknown"; silently treating it as "no storage used" would misrepresent it.
daily_archive_gb() {
    local bitrate_kbps daytime_start daytime_end keep_minutes
    bitrate_kbps=$(cfg '.encode.bitrate_kbps' 6000)
    daytime_start=$(cfg '.archive.daytime_start' 04:00)
    daytime_end=$(cfg '.archive.daytime_end' 20:30)
    keep_minutes=$(cfg '.archive.daytime_keep_minutes' 60)

    # 10# forces decimal interpretation - without it, bash arithmetic
    # treats a leading-zero hour/minute like "08" or "09" as an invalid
    # octal literal and errors out.
    local start_min end_min
    start_min=$(( 10#${daytime_start%%:*} * 60 + 10#${daytime_start##*:} ))
    end_min=$(( 10#${daytime_end%%:*} * 60 + 10#${daytime_end##*:} ))
    if (( end_min <= start_min )); then
        return 1
    fi
    awk -v kbps="$bitrate_kbps" -v win="$(( end_min - start_min ))" -v keep="$keep_minutes" '
        BEGIN {
            retained_sec_per_day = win * keep
            bytes_per_day = (kbps * 1000 / 8) * retained_sec_per_day
            printf "%.4f", bytes_per_day / 1e9
        }
    '
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

# check_archive_disk_space - B2: WARN-only, never FAIL - FR12 is explicit
# that this project does not auto-compute or enforce a storage budget, and
# this doesn't either. It's the same "helps you size your own storage"
# spirit FR12 already asks for (show_sizing_estimate, below), just compared
# against real currently-free space instead of the formula alone. Matters
# because FR11's retention policy is per-hour, not a rolling N-day window -
# once a closed hour is trimmed to daytime_keep_minutes it stays on disk
# indefinitely, so usage grows by roughly daily_archive_gb every day for
# the life of the deployment until something (the admin, or FR13's
# re-encode) intervenes.
check_archive_disk_space() {
    if ! cfg_bool '.archive.enabled' true; then
        return  # check_archive_dir already reported the skip
    fi
    local dir
    dir=$(cfg '.archive.segment_dir' /var/lib/pigeoncam/archive)
    [[ -d "$dir" ]] || return  # check_archive_dir already reports this as FAIL

    local avail_kb
    avail_kb=$(df -Pk -- "$dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$avail_kb" ]]; then
        result WARN "archive disk space" "could not determine free space on $dir (df failed)"
        return
    fi

    local gb_per_day
    if ! gb_per_day=$(daily_archive_gb); then
        return  # show_sizing_estimate already explains the unparseable window
    fi

    local avail_gb days_left daily_gb_rounded is_low
    read -r avail_gb days_left daily_gb_rounded is_low < <(awk -v kb="$avail_kb" -v daily="$gb_per_day" '
        BEGIN {
            avail_gb = kb / 1e6
            days_left = (daily > 0) ? avail_gb / daily : 999999
            printf "%.2f %.1f %.2f %d\n", avail_gb, days_left, daily, (days_left < 7) ? 1 : 0
        }
    ')

    if [[ "$is_low" == "1" ]]; then
        result WARN "archive disk space" "~${avail_gb} GB free on $dir, current config fills that in ~${days_left} day(s) at ~${daily_gb_rounded} GB/day - not enforced, just a heads-up"
    else
        result PASS "archive disk space" "~${avail_gb} GB free on $dir, ~${days_left} day(s) headroom at ~${daily_gb_rounded} GB/day"
    fi
}

# check_legacy_config_keys - the YouTube API settings used to live under a
# block called `tier2:`, with tier2_*.json credential filenames. Renamed to
# `youtube_api:` because that name was the one place internal shorthand was
# staring the operator in the face every time they edited their config.
#
# There is deliberately no dual-read fallback in the scripts: a single
# operator ran the only deployment and coordinated the config change with
# the upgrade, so a clean break beat carrying a compatibility path forever.
# That makes THIS check the entire migration story - without it, an
# un-migrated config silently reads as "YouTube API access disabled", which
# looks exactly like a working system right up until a stuck broadcast
# needs recovering and nothing happens. Hence FAIL, not WARN.
#
# Safe to delete once no un-migrated config can plausibly still exist.
check_legacy_config_keys() {
    if ! yq -e '.tier2' "$PIGEONCAM_CONFIG" >/dev/null 2>&1; then
        return
    fi
    result FAIL "config format (legacy tier2: block)" \
        "$PIGEONCAM_CONFIG still has a 'tier2:' block. It was renamed to 'youtube_api:' and is now IGNORED, which silently disables API rotation and stuck-broadcast recovery. Fix: rename the block to 'youtube_api:', and rename the three files it points at - /etc/pigeoncam/tier2_client_secret.json -> youtube_api_client_secret.json, /etc/pigeoncam/tier2_token.json -> youtube_api_token.json, /var/lib/pigeoncam/tier2_state.json -> youtube_api_state.json - updating client_secret_file/token_file/state_file to match. See $PIGEONCAM_PROJECT_ROOT/docs/YOUTUBE-API.md"
}

# recognized_config_keys - every leaf config key ANY script actually reads,
# extracted from the scripts themselves rather than hand-maintained, so this
# can't independently drift out of sync the way the timer/config duplication
# in check_timer_intervals did. Three sources, each matching how a key
# actually appears in source:
#   1. cfg('.a.b')/cfg_bool('.a.b') calls (shell) - the overwhelming majority.
#   2. a dotted path embedded inside a larger quoted string (shell) - covers
#      check_timer_intervals' own "unit|.config.key|default" pipe-table,
#      where the path is stored as data and read via a variable, not typed
#      literally into a cfg() call.
#   3. cfg(config, "a.b")/cfg_bool(config, "a.b") calls (Python, api/*.py) -
#      kept narrowly anchored to actual calls (unlike #2) because api/*.py
#      also has plenty of unrelated quoted strings (YouTube API JSON field
#      names, log-event labels) that a broader match would sweep in.
# Verified empirically against config.example.yaml (must extract every key
# there with zero misses) before this shipped - see docs/development/INCIDENTS.md.
recognized_config_keys() {
    { grep -rhoE "'\.[a-zA-Z][a-zA-Z0-9_.]*'" "$PIGEONCAM_PROJECT_ROOT"/bin/*.sh "$PIGEONCAM_PROJECT_ROOT"/lib/*.sh 2>/dev/null \
        | tr -d "'" | sed 's/^\.//'
      grep -rhoE '"[^"]*"' "$PIGEONCAM_PROJECT_ROOT"/bin/*.sh "$PIGEONCAM_PROJECT_ROOT"/lib/*.sh 2>/dev/null \
        | grep -oE '\.[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+' | sed 's/^\.//'
      grep -rhoE 'cfg(_bool)?\(config, "[a-zA-Z][a-zA-Z0-9_.]*"' "$PIGEONCAM_PROJECT_ROOT"/api/*.py 2>/dev/null \
        | sed -E 's/^cfg(_bool)?\(config, "(.*)"$/\2/'
    } | sort -u
}

# check_unrecognized_config_keys - the belt to check_legacy_config_keys:
# that one catches a specific known-obsolete block name; this catches
# anything else that parses as valid YAML, looks configured, and is never
# actually read by any script - a typo, a key renamed elsewhere without a
# matching config update, or (how this check came to exist) a value invented
# for a config template that didn't match what the code actually reads.
# Concretely: this would have caught watchdog.usb_reset.escalation_cooldown_seconds
# (the real key is cooldown_seconds) and audio.thread_queue_size (not read by
# anything - only camera.thread_queue_size is) immediately, instead of
# leaving both silently inert.
#
# WARN, not FAIL: unlike the legacy tier2: block (a known, total feature
# loss), an unrecognized key is ambiguous - it might be a genuine mistake,
# or a value kept around for a future version, or documentation-only. The
# operator needs telling either way, but this shouldn't block on a case that
# might turn out to be intentional.
check_unrecognized_config_keys() {
    local recognized
    recognized=$(recognized_config_keys)
    # Sanity floor: if source-scanning itself is badly broken (a refactor
    # moved bin/lib, or the grep pattern stops matching for some other
    # reason), every real key would look "unrecognized" at once. Silence
    # in that case rather than flooding the report with false positives -
    # config.example.yaml has 70+ real leaf keys, so anything drastically
    # short of that means the scan failed, not that the config is wrong.
    if (( $(wc -l <<<"$recognized") < 40 )); then
        result WARN "config keys (unrecognized-key scan)" "could not reliably scan $PIGEONCAM_PROJECT_ROOT/bin,lib,api for recognized config keys (found suspiciously few) - skipping this check rather than risk false positives"
        return
    fi

    local leaves unrecognized
    if ! leaves=$(yq . "$PIGEONCAM_CONFIG" 2>/dev/null | jq -r 'paths(scalars) as $p | $p | join(".")' 2>/dev/null); then
        result WARN "config keys (unrecognized-key scan)" "could not enumerate keys in $PIGEONCAM_CONFIG - skipping this check"
        return
    fi
    unrecognized=$(comm -23 <(sort -u <<<"$leaves") <(sort -u <<<"$recognized"))

    if [[ -z "$unrecognized" ]]; then
        result PASS "config keys (unrecognized-key scan)" "every key in $PIGEONCAM_CONFIG is read by some script"
        return
    fi
    local k
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        result WARN "config keys (unrecognized-key scan)" "'$k' is valid YAML but no script reads it - likely a typo, a renamed/obsolete key, or copied from an outdated example. Check the spelling against $PIGEONCAM_PROJECT_ROOT/config.example.yaml; if it's genuinely unused, remove it so it doesn't look configured when it silently isn't."
    done <<< "$unrecognized"
}

check_youtube_api() {
    if ! cfg_bool '.youtube_api.enabled' false; then
        result PASS "YouTube API access" "youtube_api.enabled=false, skipped"
        return
    fi
    if ! youtube_api_available; then
        result FAIL "YouTube API access" "youtube_api.enabled=true but no venv at $PIGEONCAM_PROJECT_ROOT/api/venv/ - see $PIGEONCAM_PROJECT_ROOT/docs/YOUTUBE-API.md (sudo apt install -y python3-venv && python3 -m venv $PIGEONCAM_PROJECT_ROOT/api/venv && $PIGEONCAM_PROJECT_ROOT/api/venv/bin/pip install -r $PIGEONCAM_PROJECT_ROOT/api/requirements.txt)"
        return
    fi

    local venv_python
    venv_python=$(youtube_api_venv_python)
    if ! "$venv_python" -c "import googleapiclient.discovery, google.oauth2.credentials, google_auth_oauthlib.flow, yaml" >/dev/null 2>&1; then
        result FAIL "YouTube API access" "$PIGEONCAM_PROJECT_ROOT/api/venv/ exists but its dependencies don't import cleanly - re-run: $PIGEONCAM_PROJECT_ROOT/api/venv/bin/pip install -r $PIGEONCAM_PROJECT_ROOT/api/requirements.txt"
        return
    fi

    local client_secret token_file stream_id ok=true mode
    client_secret=$(cfg '.youtube_api.client_secret_file' "")
    token_file=$(cfg '.youtube_api.token_file' "")
    stream_id=$(cfg '.youtube_api.persistent_stream_id' "")

    if [[ -z "$client_secret" || ! -f "$client_secret" ]]; then
        result FAIL "YouTube API access" "youtube_api.client_secret_file '$client_secret' does not exist - download it from Google Cloud Console, see $PIGEONCAM_PROJECT_ROOT/docs/YOUTUBE-API.md"
        ok=false
    fi
    if [[ -z "$token_file" || ! -f "$token_file" ]]; then
        result FAIL "YouTube API access" "youtube_api.token_file '$token_file' does not exist - run: $venv_python $(youtube_api_script_path) --authorize"
        ok=false
    elif [[ "$(stat -c '%a' -- "$token_file" 2>/dev/null)" != "600" ]]; then
        result FAIL "YouTube API access" "youtube_api.token_file '$token_file' is not mode 600"
        ok=false
    fi
    if [[ -z "$stream_id" ]]; then
        result FAIL "YouTube API access" "youtube_api.persistent_stream_id is not set"
        ok=false
    fi
    $ok && result PASS "YouTube API access" "venv, dependencies, credentials, and persistent_stream_id all present"

    mode=$(cfg '.youtube.rotation.mode' restart)
    if [[ "$mode" != "api" ]]; then
        result WARN "YouTube API access" "youtube_api.enabled=true but youtube.rotation.mode is '$mode', not 'api' - the YouTube API will only be used for last-resort stuck-broadcast recovery, not routine rotation. This may be intentional."
    fi
}

# check_reencode_timer - B3: FR13 (reencode.enabled) ships off by default
# and deliberately without a systemd timer (see the header comment in
# bin/pigeoncam-reencode.sh) - unlike every other Tier 1 feature, turning
# it on in config alone does not make anything actually run it. Easy to
# forget precisely because nothing else in this project works that way.
# WARN-only best-effort: cron has too many legitimate homes (user
# crontab, /etc/cron.d/*, /etc/crontab) to exhaustively rule out, so this
# only flags the case it can positively confirm found nothing, never
# claims a false negative as a hard FAIL.
check_reencode_timer() {
    if ! cfg_bool '.reencode.enabled' false; then
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        local state
        state=$(systemctl is-enabled pigeoncam-reencode.timer 2>/dev/null || true)
        if [[ "$state" == "enabled" || "$state" == "static" ]]; then
            result PASS "reencode timer" "reencode.enabled=true and pigeoncam-reencode.timer is enabled"
            return
        fi
    fi

    # Captured first, not piped straight into grep -q (see the pactl check
    # above for why that pattern is fragile under this script's pipefail) -
    # low-risk here given how small a crontab normally is, but consistent
    # with how every other such check in this project is now written.
    local crontab_out
    crontab_out=$(crontab -l 2>/dev/null || true)
    if grep -q 'pigeoncam-reencode' <<<"$crontab_out"; then
        result PASS "reencode timer" "reencode.enabled=true and a crontab entry mentions pigeoncam-reencode.sh"
        return
    fi
    # PIGEONCAM_DOCTOR_CRON_D_DIR overrides the real system path - same
    # testability pattern check_udev_rule uses for PIGEONCAM_DOCTOR_UDEV_DIRS,
    # so tests never need to touch the real /etc/cron.d.
    local cron_d_dir="${PIGEONCAM_DOCTOR_CRON_D_DIR:-/etc/cron.d}"
    if grep -RIlq 'pigeoncam-reencode' "$cron_d_dir" 2>/dev/null; then
        result PASS "reencode timer" "reencode.enabled=true and an entry under $cron_d_dir mentions pigeoncam-reencode.sh"
        return
    fi

    result WARN "reencode timer" "reencode.enabled=true but nothing found to invoke it automatically (no pigeoncam-reencode.timer, no matching crontab or /etc/cron.d entry) - this feature ships without a timer by default; run bin/pigeoncam-reencode.sh manually, or wire up your own low-frequency systemd timer or cron entry (see the header comment in bin/pigeoncam-reencode.sh)"
}

# check_timer_intervals - item 3c (2026-08-02 review): pigeoncam-
# rotate.timer, pigeoncam-watchdog.timer, and pigeoncam-status-check.timer
# each hard-code their own OnUnitActiveSec=, duplicating the corresponding
# config.yaml interval by hand (comments in each *.timer file say so).
# Nothing previously detected the two drifting apart. WARN-only, and
# deliberately not "generate unit files from config": that would add a
# build step to a project whose stated problem is accumulated complexity,
# for a value that changes rarely. archive-trim and ytdlp-update timers
# use OnCalendar (a daily wall-clock schedule, not an interval) and have
# no config-side interval to compare against, so they're not checked here.
check_timer_intervals() {
    local systemd_dir="${PIGEONCAM_DOCTOR_SYSTEMD_DIR:-/etc/systemd/system}"
    local -a pairs=(
        "pigeoncam-rotate.timer|.youtube.rotation.interval|11h45m"
        "pigeoncam-watchdog.timer|.watchdog.check_interval_seconds|30"
        "pigeoncam-status-check.timer|.external_check.poll_interval_seconds|180"
    )

    local pair timer cfg_key cfg_default timer_path timer_val timer_s cfg_val cfg_s
    for pair in "${pairs[@]}"; do
        IFS='|' read -r timer cfg_key cfg_default <<< "$pair"
        timer_path="$systemd_dir/$timer"
        if [[ ! -f "$timer_path" ]]; then
            result WARN "timer/config sync ($timer)" "$timer_path not installed yet - nothing to compare (see $PIGEONCAM_PROJECT_ROOT/README.md Quickstart step 5)"
            continue
        fi
        timer_val=$(grep -m1 -E '^[[:space:]]*OnUnitActiveSec[[:space:]]*=' "$timer_path" | cut -d= -f2-)
        if [[ -z "$timer_val" ]]; then
            result WARN "timer/config sync ($timer)" "no OnUnitActiveSec= found in $timer_path"
            continue
        fi
        if ! timer_s=$(parse_duration_seconds "$timer_val"); then
            result WARN "timer/config sync ($timer)" "could not parse OnUnitActiveSec='$timer_val' in $timer_path as a duration"
            continue
        fi
        cfg_val=$(cfg "$cfg_key" "$cfg_default")
        if ! cfg_s=$(parse_duration_seconds "$cfg_val"); then
            result WARN "timer/config sync ($timer)" "could not parse $cfg_key='$cfg_val' as a duration"
            continue
        fi
        if (( timer_s == cfg_s )); then
            result PASS "timer/config sync ($timer)" "OnUnitActiveSec=$timer_val matches $cfg_key ($cfg_val)"
        else
            result WARN "timer/config sync ($timer)" "OnUnitActiveSec=$timer_val (${timer_s}s) in $timer_path does not match $cfg_key=$cfg_val (${cfg_s}s) - update one to match the other, then sudo systemctl daemon-reload"
        fi
    done
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
    local u state
    for u in "${PIGEONCAM_ALL_UNITS[@]}"; do
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

    echo ""
    echo "Sizing estimate - not enforced, just a reference point:"
    echo "  storage = bitrate x retained-seconds-per-day x total-days"

    local gb_per_day
    if ! gb_per_day=$(daily_archive_gb); then
        echo "  (could not parse daytime_start/daytime_end as a same-day HH:MM window - skipping the numeric example)"
        return
    fi
    local bitrate_kbps keep_minutes
    bitrate_kbps=$(cfg '.encode.bitrate_kbps' 6000)
    keep_minutes=$(cfg '.archive.daytime_keep_minutes' 60)
    awk -v kbps="$bitrate_kbps" -v keep="$keep_minutes" -v gb="$gb_per_day" '
        BEGIN {
            printf "  current config: %skbit/s, daytime window kept at %s min/hour -> ~%.2f GB/day (~%.1f GB/30d, ~%.1f GB/90d)\n", kbps, keep, gb, gb*30, gb*90
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
    check_archive_disk_space
    check_reencode_timer
    check_legacy_config_keys
    check_unrecognized_config_keys
    check_youtube_api
    check_start_limit
    check_units_enabled
    check_timer_intervals

    show_sizing_estimate
    print_summary
    # Explicit exit, rather than letting `(( FAIL == 0 ))` fall off the end
    # as main's return status: this script's non-zero exit is a *report*
    # ("some checks failed"), not a fault, and a bare non-zero return from
    # the top-level `main "$@"` would trip lib/pigeoncam-common.sh's ERR
    # trap and announce "this is a bug, not a normal fault" on a completely
    # normal doctor run. A plain `exit N` does not trip the trap (verified
    # directly), while real failures deeper inside still do - which is the
    # whole point of keeping the trap.
    if (( FAIL > 0 )); then
        exit 1
    fi
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Deliberately a BARE `main "$@"` - main() above exits explicitly, which
    # is what keeps the ERR trap quiet on a normal "some checks FAILed" run.
    #
    # Do NOT "fix" a spurious trap message here by writing
    # `main "$@" || exit $?`. That puts main in a condition context, which
    # disables `set -e` for main *and everything it calls*, recursively -
    # measured directly: a script written that way ran straight past a
    # failing command and exited 0. Harmless-looking here (this script sets
    # -uo pipefail, no -e) but catastrophic if copied to any of the
    # set -euo pipefail scripts, where it would silently undo both set -e
    # and the ERR trap in one line. tests/test_err_trap.sh fails the build
    # if that pattern appears anywhere in bin/.
    main "$@"
fi

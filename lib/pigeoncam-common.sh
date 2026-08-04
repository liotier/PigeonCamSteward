# shellcheck shell=bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-common.sh - shared helpers sourced by the bin/pigeoncam-*.sh scripts.
# Not meant to be executed directly; source it, don't run it.
#
# Config access goes through `yq` (the kislyuk/yq wrapper around jq, package
# "yq" on Debian/Ubuntu) rather than a hand-rolled YAML parser: it shares jq's
# filter syntax, and jq is already a project dependency (FR7c/pigeoncam-status-
# check.sh). This is one addition beyond the dependency table in SPEC.md §6a;
# see README for the note.

if [[ -n "${PIGEONCAM_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
PIGEONCAM_COMMON_SH_LOADED=1

PIGEONCAM_CONFIG="${PIGEONCAM_CONFIG:-/etc/pigeoncam/config.yaml}"

# shellcheck disable=SC2034  # used by bin/pigeoncam-{watchdog,status-check,rotate}.sh, not this file
PIGEONCAM_STREAM_UNIT="pigeoncam-stream.service"

# Every unit README Quickstart step 5 installs and enables, in start/enable
# order (pigeoncam-ctl.sh stop/disable walk this same list in reverse - see
# there). Single source of truth shared by pigeoncam-ctl.sh (start/stop/
# restart/enable/disable/status, one command instead of naming all six by
# hand) and pigeoncam-doctor.sh's check_units_enabled() (B1), so the two
# can't silently drift apart as units are added.
# shellcheck disable=SC2034  # used by bin/pigeoncam-ctl.sh and bin/pigeoncam-doctor.sh, not this file
PIGEONCAM_ALL_UNITS=(
    pigeoncam-stream.service
    pigeoncam-watchdog.timer
    pigeoncam-status-check.timer
    pigeoncam-rotate.timer
    pigeoncam-archive-trim.timer
    pigeoncam-ytdlp-update.timer
)

# Computed once at load time, relative to this file's own location (not the
# caller's) - BASH_SOURCE[0] inside a function retains the source file it
# was *defined* in, regardless of which script calls it.
_PIGEONCAM_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=./pigeoncam-solar.sh
source "$_PIGEONCAM_LIB_DIR/pigeoncam-solar.sh"

# The actual install root (e.g. /opt/PigeonCamSteward, but a script never
# assumes that - some deployments choose otherwise). Runtime messages that
# point at another project file (docs/*.md, README.md, systemd/*, ...)
# should use this to print a real, unambiguous absolute path - the script
# already knows exactly where it lives, so it should just say so, rather
# than a relative reference that only resolves correctly if the reader
# happens to be sitting in this directory. Documentation prose and
# config.example.yaml comments are the opposite case: they use paths
# relative to the install root instead, since the reader chose that root
# themselves and a hardcoded /opt/PigeonCamSteward would be presumptuous.
# shellcheck disable=SC2034  # used by bin/pigeoncam-*.sh, not this file
PIGEONCAM_PROJECT_ROOT=$(cd -- "$_PIGEONCAM_LIB_DIR/.." && pwd)
# Overridable (test-only, like PIGEONCAM_PULSE_RUNTIME_BASE below) so tests
# can point youtube_api_available() at a fixture venv+script instead of this
# checkout's real api/ - real deployments never set this.
PIGEONCAM_API_DIR="${PIGEONCAM_API_DIR:-$PIGEONCAM_PROJECT_ROOT/api}"
# Durable (survives reboot) counterpart to pigeoncam_run_dir()'s tmpfs -
# see durable_marker_path() below (item 3a, 2026-08-02 review). Same
# default youtube_api.state_file already uses (config.example.yaml), but not
# derived from that config key: last_rotation_at must resolve the same
# way whether or not Tier 2 is configured, and coupling a Tier 1 marker
# path to a YAML lookup would mean a test fixture's youtube_api: block and this
# path could silently drift apart. Overridable (test-only, same pattern
# as PIGEONCAM_API_DIR above) so tests never write into the real
# /var/lib/pigeoncam.
PIGEONCAM_DURABLE_DIR="${PIGEONCAM_DURABLE_DIR:-/var/lib/pigeoncam}"

# --- Tier 2 (FR15) availability -------------------------------------------
# Tier 2 is considered "installed" only when its venv actually exists, not
# merely when api/rotate_via_api.py is present - SPEC.md §6a requires
# isolating its dependencies in a virtualenv rather than system Python, and
# running the script against system Python without google-api-python-client
# etc. installed would just fail with an ImportError. Always invoke it via
# the venv's own interpreter explicitly, never rely on the script's shebang
# + PATH resolution picking the right one.
youtube_api_venv_python() {
    local candidate="$PIGEONCAM_API_DIR/venv/bin/python3"
    [[ -x "$candidate" ]] && printf '%s' "$candidate"
}

youtube_api_script_path() {
    printf '%s' "$PIGEONCAM_API_DIR/rotate_via_api.py"
}

youtube_api_available() {
    if ! cfg_bool '.youtube_api.enabled' false; then
        return 1
    fi
    local py
    py=$(youtube_api_venv_python)
    [[ -n "$py" && -f "$(youtube_api_script_path)" ]]
}

# youtube_api_run <args...> - runs rotate_via_api.py via its venv interpreter.
# Callers check youtube_api_available first; this does not re-check.
youtube_api_run() {
    "$(youtube_api_venv_python)" "$(youtube_api_script_path)" "$@"
}

# --- logging -------------------------------------------------------------
# Each script sets PIGEONCAM_LOG_TAG before calling these. Under systemd,
# stdout/stderr are already captured into the journal under the owning
# unit's SyslogIdentifier (see systemd/*.service), so we just print clearly
# labeled lines rather than shelling out to logger(1) - this also keeps
# manual/interactive/test runs readable without a syslog socket present.
: "${PIGEONCAM_LOG_TAG:=pigeoncam}"

_pigeoncam_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_info()  { printf '%s [%s] INFO  %s\n' "$(_pigeoncam_ts)" "$PIGEONCAM_LOG_TAG" "$*"; }
log_warn()  { printf '%s [%s] WARN  %s\n' "$(_pigeoncam_ts)" "$PIGEONCAM_LOG_TAG" "$*" >&2; }
log_error() { printf '%s [%s] ERROR %s\n' "$(_pigeoncam_ts)" "$PIGEONCAM_LOG_TAG" "$*" >&2; }

# --- ERR trap: make silent script death impossible --------------------
# Three separate production incidents so far shared one shape: a bare
# `x=$(pipeline)` assignment failing under `set -euo pipefail`, which made
# set -e exit the whole script at that line - before it had logged
# anything at all. The watchdog died silently for an unknown period, more
# than once, this exact way (see docs/development/INCIDENTS.md, plus a
# fourth near-miss caught only because it
# happened to be measured before shipping). Individual instances are
# fixed; this closes the class - any future unguarded failure anywhere in
# a script that sources this file now logs a diagnostic before set -e
# exits, instead of exiting silently.
#
# `set -o errtrace` is not optional: without it, an ERR trap does not
# fire inside shell functions - which is exactly where all of the above
# happened. Verified directly (a two-file lib/caller split, matching this
# project's real structure): with errtrace set, BASH_SOURCE[1]/
# BASH_LINENO[0] inside the trap function correctly resolve to the
# *calling* script's failing line, not this file's.
#
# Does NOT fire for a command whose failure is being tested (`if cmd`,
# `cmd || fallback`, `cmd && next`, `! cmd`) - the same exemptions set -e
# itself has, confirmed empirically. That is deliberate: this project's
# many intentional `|| return 0` / `if ! cmd; then` guards are handled
# failure, not a bug, and must stay silent. Only an unguarded, unexpected
# failure - a real bug - reaches this trap. It does not change control
# flow: set -e still exits right after. It only guarantees a diagnostic
# gets logged first, since silently continuing past an unexpected failure
# is exactly how a watchdog ends up reporting healthy while blind.
pigeoncam_on_err() {
    local rc=$? line=${BASH_LINENO[0]:-?} cmd=$BASH_COMMAND
    log_error "unhandled failure at ${BASH_SOURCE[1]:-?}:${line} (exit ${rc}) running: ${cmd}"
    log_error "this is a bug, not a normal fault - a script is about to exit without having explained why. See docs/development/INCIDENTS.md"
}
set -o errtrace
trap pigeoncam_on_err ERR

# log_event LABEL message... - FR8: distinct, greppable labels for each
# restart trigger (STALL_RESTART, USB_RESET_ESCALATION, EXTERNAL_RESTART,
# ESCALATION_UNAVAILABLE, ...) on top of the per-unit journal separation
# systemd already gives for free via each script's own service unit.
log_event() {
    local label="$1"; shift
    printf '%s [%s] EVENT %s %s\n' "$(_pigeoncam_ts)" "$PIGEONCAM_LOG_TAG" "$label" "$*"
}

# notify_escalation LABEL message... - C2: like log_event (always logs,
# same label/message), but additionally invokes the optional
# notify_command config hook. Reserved for genuine escalations (FR7b's
# USB-level device reset, FR7e's Tier 2 API recovery and its last-resort
# "manual Studio intervention may be required" case) - deliberately NOT
# called for every routine automatic restart (STALL_RESTART,
# EXTERNAL_RESTART), which would make a notification channel too noisy
# to be useful. Best-effort: a failing, unset, or slow (>10s)
# notify_command is logged as a warning but never affects the escalation
# itself, and never raises.
notify_escalation() {
    local label="$1"; shift
    log_event "$label" "$@"

    local cmd
    cmd=$(cfg '.notify_command' "")
    [[ -n "$cmd" ]] || return 0

    # sh -c "$cmd" sh "$label" "$*" - label/message land in the user's
    # command as $1/$2 if they choose to reference them (e.g. a one-liner
    # piping into curl/mail/notify-send); anything more elaborate is
    # easiest as the user's own small wrapper script pointed to here.
    local out
    if ! out=$(timeout 10 sh -c "$cmd" sh "$label" "$*" 2>&1); then
        log_warn "notify_command failed or timed out (label=$label): ${out:-no output}"
    fi
}

# --- config access ---------------------------------------------------------
# cfg <yq/jq filter> [default]
#
# Deliberately does NOT use jq's `//` alternative operator: `//` treats a
# real `false` the same as `null`/missing (a well-known jq gotcha), which
# would silently coerce any false-valued boolean key (archive.enabled: false,
# watchdog.usb_reset.enabled: false, ...) into its default instead. Instead
# we read the raw value and only fall back to $default when it is literally
# absent (yq/jq prints the bare word `null` for both a missing path and an
# explicit null).
cfg() {
    local filter="$1" default="${2:-}" value
    if [[ ! -f "$PIGEONCAM_CONFIG" ]]; then
        log_error "config file not found: $PIGEONCAM_CONFIG (copy config.example.yaml and edit it)"
        exit 1
    fi
    if ! value=$(yq -r "$filter" "$PIGEONCAM_CONFIG" 2>/dev/null); then
        log_error "failed to evaluate '$filter' against $PIGEONCAM_CONFIG (invalid YAML or filter?)"
        exit 1
    fi
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

# cfg_bool <filter> [default: true|false] - normalized boolean accessor for
# use directly in [[ ... ]] tests: cfg_bool '.archive.enabled' true && ...
cfg_bool() {
    local v
    v=$(cfg "$1" "${2:-false}")
    [[ "${v,,}" == "true" ]]
}

# --- run-time directory & marker files --------------------------------------
# There is no dedicated `general.run_dir` config key; the shared runtime
# directory is derived from watchdog.progress_file's parent, since that path
# is already the one fixed point every Tier 1 script needs to agree on.
pigeoncam_run_dir() {
    local pf
    pf=$(cfg '.watchdog.progress_file' '/run/pigeoncam/progress')
    dirname -- "$pf"
}

marker_path() { # marker_path <filename>
    printf '%s/%s' "$(pigeoncam_run_dir)" "$1"
}

# durable_marker_path <filename> - like marker_path(), but under
# PIGEONCAM_DURABLE_DIR (persistent storage) instead of the tmpfs run
# dir. Item 3a, 2026-08-02 review: last_rotation_at moved here because a
# reboot must not make an already-overdue broadcast look freshly rotated
# (see write_epoch_marker's comment below, and item 3b's age check in
# bin/pigeoncam-rotate.sh).
durable_marker_path() { # durable_marker_path <filename>
    printf '%s/%s' "$PIGEONCAM_DURABLE_DIR" "$1"
}

# write_epoch_marker <path> - records "now" in epoch seconds. Used for:
#  - started_at:       written by pigeoncam-stream.sh at every process start
#                       (crash restart, watchdog restart, rotation restart -
#                       all funnel through the same script, so one marker
#                       covers FR7c's grace_period_after_restart_seconds).
#                       Deliberately stays in marker_path (tmpfs): "when did
#                       the current ffmpeg process start" is meaningless
#                       across a reboot, and a stale value here would
#                       suppress grace_period_after_restart_seconds exactly
#                       when it's needed - swapping this with last_rotation_at
#                       below would be worse than the bug item 3a fixes.
#  - last_rotation_at: written by pigeoncam-rotate.sh at the moment it begins
#                       the stop->gap->start sequence (not after), so the
#                       marker covers the full gap window per FR14's "must
#                       cover the full interval-plus-gap" requirement. Lives
#                       in durable_marker_path (persistent, item 3a): unlike
#                       started_at, how long ago the broadcast last rotated
#                       is exactly as true after a reboot as before one, and
#                       item 3b's age check depends on that surviving.
write_epoch_marker() {
    local path="$1"
    mkdir -p -- "$(dirname -- "$path")"
    date +%s > "$path"
}

# seconds_since_marker <path> - prints elapsed seconds, or a very large
# number if the marker is missing/unreadable so grace-period comparisons
# default to "not recent" (fail open toward normal fault evaluation) rather
# than crashing or silently suppressing checks forever.
seconds_since_marker() {
    local path="$1" ts now
    if [[ -f "$path" ]] && ts=$(cat -- "$path" 2>/dev/null) && [[ "$ts" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
        printf '%d' "$(( now - ts ))"
    else
        printf '%d' 999999999
    fi
}

# parse_duration_seconds <spec> - converts a systemd-timespan-style
# duration (e.g. "11h45m", "11h 45min", "180s", or a bare "30" meaning
# seconds) to whole seconds on stdout. Returns non-zero with nothing
# printed if any part of it fails to parse. Item 3b/3c, 2026-08-02
# review: bin/pigeoncam-rotate.sh's age check and pigeoncam-doctor.sh's
# timer/config sync check both need to compare a config.yaml duration
# string against a systemd unit's OnUnitActiveSec= value in the same
# units. Deliberately not a full systemd.time(7) implementation (see
# systemd.time(7) for everything this doesn't handle, e.g. "day"/"week"/
# "ago") - only the unit spellings this project's own config and shipped
# *.timer files actually use.
parse_duration_seconds() {
    # Strip spaces (systemd writes "11h 45min") and any CR, so a unit file
    # saved with CRLF line endings doesn't fail to parse for an invisible
    # reason.
    local spec="${1//[[:space:]]/}" total=0
    spec="${spec//$'\r'/}"
    [[ -n "$spec" ]] || return 1
    local num unit
    while [[ -n "$spec" ]]; do
        if [[ "$spec" =~ ^([0-9]+)(h|min|m|s)? ]]; then
            # 10# forces decimal: without it, a perfectly reasonable
            # "08h30m" or "09h" makes bash arithmetic read 08/09 as an
            # invalid octal literal and abort the whole function with a
            # raw "value too great for base" error. Exactly the trap
            # pigeoncam-doctor.sh's daily_archive_gb already documents for
            # leading-zero HH:MM times - found again here by adversarial
            # review, before any user hit it.
            num="10#${BASH_REMATCH[1]}"
            unit="${BASH_REMATCH[2]}"
            case "$unit" in
                h)     total=$(( total + num * 3600 )) ;;
                min|m) total=$(( total + num * 60 )) ;;
                s|"")  total=$(( total + num )) ;;
            esac
            spec="${spec:${#BASH_REMATCH[0]}}"
        else
            return 1
        fi
    done
    printf '%d' "$total"
}

# --- progress file (FR7) ----------------------------------------------------
# ffmpeg's -progress target is opened for append, never truncated, across
# separate process invocations (verified empirically: two short ffmpeg runs
# against the same path left both runs' blocks in the file). pigeoncam-
# stream.sh truncates it at the start of every run so it doesn't grow
# unbounded across a multi-week deployment's worth of restarts; within a
# single run it still grows continuously, so callers here always look at the
# END of the file, not the start.

# progress_last_frame <progress_file> - prints the most recent `frame=`
# value, or empty if none found yet (e.g. ffmpeg still starting up).
#
# `tail -n 20` (not `tac` over the whole file) is load-bearing, not a
# style choice: `tac | grep -m1 | cut` reproduced in production as a
# near-total, completely silent outage of this whole script. `-progress`
# writes one ~11-line block per second and the file is never truncated
# within a run, so after any real runtime it can reach many thousands of
# lines; `tac` has to read and reverse the entire file before writing
# anything out, while `grep -m1` finds its match (the block that's now
# first, post-reversal) within the first handful of lines and exits
# immediately - closing the pipe while `tac` is typically still mid-write
# on the rest of the (reversed) file, which kills `tac` with SIGPIPE.
# Under this script's `pipefail`, that makes the whole pipeline "fail"
# even though the correct value already printed - and since
# bin/pigeoncam-watchdog.sh assigns the result via a bare
# `cur_frame=$(...)`, not inside an `if`, `set -e` then kills the entire
# watchdog invocation on the spot, before it has logged a single line.
# Reproduced directly against a 220,000-line synthetic progress file
# (pipeline exit 141) before landing this fix. `tail -n 20` avoids the
# failure mode entirely - GNU tail seeks from the end of a regular file
# instead of reading it forward, so it's cheaper than `tac` was besides -
# and every stage below it reads its input to completion, so nothing
# downstream can close the pipe early against a still-writing upstream.
# The `|| return 0` on the assignment below covers the *second* way this
# same function killed the watchdog in production (2026-08-02), distinct
# from the SIGPIPE race described above and not fixed by it: when the
# progress file exists but contains no `frame=` line yet, `grep` exits 1,
# pipefail propagates that, and the caller's bare `cur_frame=$(...)` under
# `set -e` again kills the whole script with no output whatsoever. That
# state is not an error - it is this function's own documented "empty if
# none found yet (e.g. ffmpeg still starting up)" contract, and it happens
# on every single stream restart, because pigeoncam-stream.sh truncates the
# progress file at startup and ffmpeg needs a moment to write its first
# block. Net effect in production: the watchdog was blind for the first
# ~30s after every restart - precisely when a just-restarted stream is
# least stable and the watchdog is most needed.
progress_last_frame() {
    local pf="$1" line
    [[ -f "$pf" ]] || return 0
    line=$(tail -n 20 -- "$pf" 2>/dev/null | grep '^frame=' | tail -1) || return 0
    printf '%s' "${line#frame=}"
}

# progress_age_seconds <progress_file> - seconds since the file was last
# written to; a very large number if it doesn't exist yet (treated as "not
# stalled, just not started" by callers that also check process/start age).
progress_age_seconds() {
    local pf="$1" mtime now
    if [[ -f "$pf" ]] && mtime=$(stat -c '%Y' -- "$pf" 2>/dev/null); then
        now=$(date +%s)
        printf '%d' "$(( now - mtime ))"
    else
        printf '%d' 999999999
    fi
}

# local_health_ok - coarse yes/no gate shared between pigeoncam-watchdog.sh
# (which additionally does its own frame-comparison/escalation bookkeeping)
# and pigeoncam-status-check.sh (FR7d: "while local frame-progress (FR7)
# remains healthy"). Healthy means the progress file has been written to
# within stall_timeout_seconds; a not-yet-existing progress file (fresh
# start) is treated as healthy so the two scripts don't fight the startup
# grace period Appendix A calls out.
local_health_ok() {
    local pf stall_timeout age
    pf=$(cfg '.watchdog.progress_file' '/run/pigeoncam/progress')
    stall_timeout=$(cfg '.watchdog.stall_timeout_seconds' 60)
    if [[ ! -f "$pf" ]]; then
        return 0
    fi
    age=$(progress_age_seconds "$pf")
    (( age < stall_timeout ))
}

# --- audio.mode=real cross-user PulseAudio/PipeWire bridge -----------------
# resolve_pulse_bridge_env <user> - exports PULSE_SERVER and PULSE_COOKIE so
# a process running as a different user (root, always, for every unit in
# this project - FR6) can connect to <user>'s PipeWire/PulseAudio session as
# a client. Needed because those sessions are per-user (a socket at
# /run/user/<uid>/pulse/native, auth'd via a per-user cookie file) and root
# has none of its own - discovered the hard way when root's own `pactl`/
# `ffmpeg -f pulse` calls had nothing to connect to even though the source
# was enumerable just fine under the owning user's own session.
# Exports nothing and returns 1 if <user> doesn't exist or has no active
# session (socket missing - `loginctl enable-linger <user>` keeps one alive
# without an interactive login), so callers never proceed with a stale or
# half-set bridge.
# PIGEONCAM_PULSE_RUNTIME_BASE overrides the "/run/user" prefix; test-only,
# real deployments never need it.
resolve_pulse_bridge_env() {
    local user="$1" uid home socket runtime_base
    uid=$(id -u "$user" 2>/dev/null) || return 1
    home=$(getent passwd "$user" | cut -d: -f6)
    runtime_base="${PIGEONCAM_PULSE_RUNTIME_BASE:-/run/user}"
    socket="${runtime_base}/${uid}/pulse/native"
    [[ -S "$socket" ]] || return 1
    export PULSE_SERVER="unix:${socket}"
    export PULSE_COOKIE="${home}/.config/pulse/cookie"
}

# --- misc --------------------------------------------------------------
# segment_ext_for_format <segment_format> - file extension matching
# archive.segment_format (FR10 defaults to mpegts/.ts).
segment_ext_for_format() {
    case "$1" in
        mpegts) printf 'ts' ;;
        mp4)    printf 'mp4' ;;
        matroska|mkv) printf 'mkv' ;;
        *) printf '%s' "$1" ;; # unrecognized: assume the format name IS the extension
    esac
}

require_cmd() { # require_cmd <name>... - fatal if any is missing from PATH
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "required command(s) not found in PATH: ${missing[*]}"
        exit 1
    fi
}

# fetch_live_json - queries external_check.channel_live_url via yt-dlp and
# prints the raw JSON on stdout. Exit 0 = extraction succeeded (the URL
# resolved to SOMETHING, whether or not that something is currently live);
# exit non-zero = extraction failed outright (network/DNS/frontend-change).
# This exit-code/JSON-validity split, not stderr text matching, is what lets
# callers distinguish "confirmed not live" from "indeterminate" (FR7c)
# without depending on yt-dlp's human-readable error strings, which are
# exactly the kind of unstable interface FR7 avoided for the same reason.
fetch_live_json() {
    local method
    method=$(cfg '.external_check.method' yt-dlp)
    if [[ "$method" != "yt-dlp" ]]; then
        # FR7c mentions a quota-based `api` alternative as secondary to
        # Tier 2's two core deliverables (rotate_via_api.py's own rotation
        # mode, and FR7e recovery) - not implemented. Fail closed
        # (indeterminate, via a non-zero return) rather than silently
        # falling back to yt-dlp anyway, which would make the config
        # setting a no-op with no visible sign anything was wrong.
        log_error "external_check.method '$method' is not implemented (only 'yt-dlp' is) - treating this poll as indeterminate"
        return 1
    fi

    local url timeout_s
    url=$(cfg '.external_check.channel_live_url')
    timeout_s=$(cfg '.external_check.yt_dlp_timeout_seconds' 30)
    if [[ -z "$url" ]]; then
        log_error "external_check.channel_live_url is not set"
        return 1
    fi
    timeout "${timeout_s}" yt-dlp -j --no-warnings --no-playlist "$url" 2>/dev/null
}

# --- daytime window (shared by archive trimming and the frame-freeze check) -
# hour_in_daytime <HH:MM> <start HH:MM> <end HH:MM> - fixed-width zero-
# padded HH:MM strings sort lexicographically the same as chronologically,
# so plain string comparison is sufficient; does not handle a window
# wrapping past midnight (not a configuration SPEC.md anticipates). Was
# local to pigeoncam-archive-trim.sh (FR11); promoted here so
# pigeoncam-status-check.sh's frame-freeze check (below) reads the exact
# same archive.daytime_start/daytime_end window instead of a second,
# possibly-drifting copy of this comparison.
hour_in_daytime() {
    local hour="$1" start="$2" end="$3"
    [[ "$hour" > "$start" || "$hour" == "$start" ]] && [[ "$hour" < "$end" ]]
}

# current_hhmm - HH:MM right now, or $PIGEONCAM_NOW_HHMM if set. Real
# deployments never set that override; it exists solely so tests can
# exercise hour_in_daytime's callers deterministically regardless of
# whatever time of day the test happens to actually run.
current_hhmm() {
    printf '%s' "${PIGEONCAM_NOW_HHMM:-$(date +%H:%M)}"
}

# current_date_ymd - today's LOCAL calendar date as YYYYMMDD, or
# $PIGEONCAM_NOW_YMD if set. Same override pattern as current_hhmm, and
# for the same reason: hour_is_daytime's solar path needs a date, not just
# an hour, and tests need to control it deterministically.
current_date_ymd() {
    printf '%s' "${PIGEONCAM_NOW_YMD:-$(date +%Y%m%d)}"
}

_pigeoncam_solar_fallback_warned=0

# _pigeoncam_fixed_hour_in_daytime <HH> - the fixed-window comparison
# hour_is_daytime falls back to (see below), factored out because that
# fallback has three separate call sites (solar mode's own default path
# never uses this, but its two failure paths - invalid location, and a
# date/time that fails to parse - both do).
_pigeoncam_fixed_hour_in_daytime() {
    local hh="$1" daytime_start daytime_end
    daytime_start=$(cfg '.archive.daytime_start' 04:00)
    daytime_end=$(cfg '.archive.daytime_end' 20:30)
    hour_in_daytime "${hh}:00" "$daytime_start" "$daytime_end"
}

# hour_is_daytime <YYYYMMDD> <HH> - true if the given LOCAL hour counts as
# "daytime", dispatching on archive.daytime_mode:
#   fixed (default) - delegates to hour_in_daytime against
#     archive.daytime_start/daytime_end, bit-identical to the pre-solar
#     behaviour. <YYYYMMDD> is ignored in this mode.
#   solar - resolves <YYYYMMDD> <HH>:30 (the hour's midpoint, matching the
#     existing whole-hour rounding convention) to an instant and asks
#     solar_is_above (lib/pigeoncam-solar.sh) against
#     archive.solar_altitude_degrees.
#
# <YYYYMMDD> is the CALENDAR DATE THE HOUR BELONGS TO, not necessarily
# today - pigeoncam-archive-trim.sh sweeps backlog from previous days, and
# judging a backlog hour's daytime-ness by today's sun rather than that
# day's would be a real bug (several hours off in December vs June), not
# just an approximation. Callers checking "right now" pass
# current_date_ymd/current_hhmm's hour, same as they always did for the
# fixed-only version of this check.
#
# A solar-mode call that can't actually go solar (location missing/
# invalid, or the date/time fails to resolve) falls back to the fixed
# window instead - a scheduling feature must never be able to make this
# gate stop working - logging exactly one warning per process, not one per
# call, since pigeoncam-archive-trim.sh can call this many times in a
# single run while sweeping backlog.
hour_is_daytime() {
    local ymd="$1" hh="$2" mode
    mode=$(cfg '.archive.daytime_mode' fixed)
    if [[ "$mode" != "solar" ]]; then
        _pigeoncam_fixed_hour_in_daytime "$hh"
        return
    fi

    local lat lon
    lat=$(cfg '.location.latitude' '')
    lon=$(cfg '.location.longitude' '')
    if ! solar_latitude_valid "$lat" || ! solar_longitude_valid "$lon"; then
        if (( ! _pigeoncam_solar_fallback_warned )); then
            log_warn "archive.daytime_mode is 'solar' but location.latitude/location.longitude are missing or invalid (lat='$lat' lon='$lon') - falling back to the fixed archive.daytime_start/daytime_end window this run. Set both in $PIGEONCAM_CONFIG."
            _pigeoncam_solar_fallback_warned=1
        fi
        _pigeoncam_fixed_hour_in_daytime "$hh"
        return
    fi

    local threshold epoch
    threshold=$(cfg '.archive.solar_altitude_degrees' -12)
    if ! epoch=$(date -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} ${hh}:30:00" +%s 2>/dev/null) || [[ -z "$epoch" ]]; then
        if (( ! _pigeoncam_solar_fallback_warned )); then
            log_warn "archive.daytime_mode is 'solar' but '$ymd $hh:30' could not be resolved to a timestamp - falling back to the fixed archive.daytime_start/daytime_end window this run."
            _pigeoncam_solar_fallback_warned=1
        fi
        _pigeoncam_fixed_hour_in_daytime "$hh"
        return
    fi

    solar_is_above "$epoch" "$lat" "$lon" "$threshold"
}

# --- frame-freeze check (FR7c/d's blind spot: a broadcast can report
# confirmed-live while YouTube's own relay to viewers is stuck replaying
# stale content - local frame progress (FR7) and yt-dlp's is_live
# extraction both look completely healthy in that case, since neither can
# see YouTube's own relay state) --------------------------------------------

# resolve_live_media_url <channel_live_url> <timeout_seconds> - resolves to
# a real, directly-fetchable media URL via yt-dlp -g. A different yt-dlp
# invocation from fetch_live_json's -j above, with its own independent
# failure mode - empty output on any failure, never fatal to the caller.
resolve_live_media_url() {
    local url="$1" timeout_s="$2"
    timeout "$timeout_s" yt-dlp -g -f best --no-warnings --no-playlist "$url" 2>/dev/null | head -n 1
}

# frame_hash_from_url <media_url> <timeout_seconds> - decodes exactly one
# frame from a direct media URL and hashes its raw decoded pixels. Raw
# decoded output, not the compressed bitstream and not a re-encoded image
# format - either would introduce its own encoding variance that has
# nothing to do with whether the actual video content changed, defeating
# the comparison this exists for. Empty output on any failure - never
# fatal to the caller.
#
# `set -o pipefail` inside the command substitution (local to its own
# subshell, exactly like every other use of a subshelled `set` in this
# project) is load-bearing, not a style choice: sha256sum happily hashes
# zero bytes into a valid-looking hash regardless of *why* its input was
# empty, so without pipefail a failing ffmpeg upstream would be silently
# masked into a "successful" hash-of-nothing instead of the empty output
# this function's contract promises on failure. The `|| return 0` around
# it, not a bare assignment, is what actually lets that propagate - the
# same bare-assignment-under-set-e trap documented at length on
# progress_last_frame below.
frame_hash_from_url() {
    local media_url="$1" timeout_s="$2" hash
    hash=$(set -o pipefail; timeout "$timeout_s" ffmpeg -y -loglevel error -i "$media_url" -frames:v 1 -f rawvideo -pix_fmt yuv420p - 2>/dev/null | sha256sum | cut -d' ' -f1) || return 0
    printf '%s' "$hash"
}

# current_live_frame_hash <channel_live_url> <timeout_seconds> - the two
# above, composed. Empty output if either step fails (network/extractor
# issue, stream briefly unavailable, ...) - callers must treat that as
# indeterminate and not count it either way, exactly like fetch_live_json's
# own failure mode.
current_live_frame_hash() {
    local url="$1" timeout_s="$2" media_url
    media_url=$(resolve_live_media_url "$url" "$timeout_s")
    [[ -n "$media_url" ]] || return 0
    frame_hash_from_url "$media_url" "$timeout_s"
}

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

# Computed once at load time, relative to this file's own location (not the
# caller's) - BASH_SOURCE[0] inside a function retains the source file it
# was *defined* in, regardless of which script calls it.
_PIGEONCAM_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

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
# can point tier2_available() at a fixture venv+script instead of this
# checkout's real api/ - real deployments never set this.
PIGEONCAM_API_DIR="${PIGEONCAM_API_DIR:-$PIGEONCAM_PROJECT_ROOT/api}"

# --- Tier 2 (FR15) availability -------------------------------------------
# Tier 2 is considered "installed" only when its venv actually exists, not
# merely when api/rotate_via_api.py is present - SPEC.md §6a requires
# isolating its dependencies in a virtualenv rather than system Python, and
# running the script against system Python without google-api-python-client
# etc. installed would just fail with an ImportError. Always invoke it via
# the venv's own interpreter explicitly, never rely on the script's shebang
# + PATH resolution picking the right one.
tier2_venv_python() {
    local candidate="$PIGEONCAM_API_DIR/venv/bin/python3"
    [[ -x "$candidate" ]] && printf '%s' "$candidate"
}

tier2_script_path() {
    printf '%s' "$PIGEONCAM_API_DIR/rotate_via_api.py"
}

tier2_available() {
    if ! cfg_bool '.tier2.enabled' false; then
        return 1
    fi
    local py
    py=$(tier2_venv_python)
    [[ -n "$py" && -f "$(tier2_script_path)" ]]
}

# tier2_run <args...> - runs rotate_via_api.py via its venv interpreter.
# Callers check tier2_available first; this does not re-check.
tier2_run() {
    "$(tier2_venv_python)" "$(tier2_script_path)" "$@"
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

# write_epoch_marker <path> - records "now" in epoch seconds. Used for:
#  - started_at:       written by pigeoncam-stream.sh at every process start
#                       (crash restart, watchdog restart, rotation restart -
#                       all funnel through the same script, so one marker
#                       covers FR7c's grace_period_after_restart_seconds).
#  - last_rotation_at: written by pigeoncam-rotate.sh at the moment it begins
#                       the stop->gap->start sequence (not after), so the
#                       marker covers the full gap window per FR14's "must
#                       cover the full interval-plus-gap" requirement.
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
progress_last_frame() {
    local pf="$1"
    [[ -f "$pf" ]] || return 0
    tail -n 20 -- "$pf" 2>/dev/null | grep '^frame=' | tail -1 | cut -d= -f2
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

#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-setup.sh - interactive, re-runnable wizard that fills in
# config.yaml by asking a fixed set of questions, so a new operator does
# not have to read all 438 lines of config.example.yaml before their first
# stream. Spec: docs/development/design/setup-script.md.
#
# The constraint that shapes everything below: config.example.yaml is 438
# lines, of which 323 are comments - the project's real configuration
# documentation, including field-earned warnings like the
# KNOWN-HARMFUL-AS-SHIPPED note on watchdog.frame_freeze. A `yq` round-trip
# (parse to a data structure, re-serialise) destroys every one of them -
# verified: `yq -y . config.example.yaml` emits a clean, comment-free file.
# So this script never parses-and-rewrites. For each answer, it finds the
# ONE line that already sets that key (yaml_find_line below, which tracks
# a path stack exactly like pigeoncam-doctor.sh's own duplicate-key
# scanner, so `youtube.rotation.mode` and `external_check.frame_border.mode`
# - the same leaf name at the same indentation - are never confused) and
# rewrites only that line's value (render_new_line below), leaving every
# comment, blank line, and unrelated key byte-for-byte untouched. The
# headline test in tests/test_setup.sh asserts the comment count is
# unchanged after a run - that is what stops someone "simplifying" this
# into a yq round-trip later.
#
# Deliberately a standalone script, not debian/postinst: postinst
# frequently runs where nobody can answer (unattended upgrades,
# DEBIAN_FRONTEND=noninteractive, preseeded installs), and most of the
# answers here don't exist at install time anyway - the stream key needs a
# visit to YouTube Studio, the channel URL needs a channel to already
# exist. This works identically whether the project arrived by `git clone`
# or by a package; a package's postinst just prints "run this next".

set -uo pipefail   # deliberately no -e: a validation failure here is normal,
                    # expected control flow (bad input, an unanswerable
                    # question in non-interactive mode), not a bug - this
                    # script reports it with a clear message and an explicit
                    # exit, the same "aggregate and exit explicitly, never
                    # trip the ERR trap on a normal outcome" shape
                    # pigeoncam-doctor.sh and pigeoncam-ctl.sh already use
                    # for the same reason.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/pigeoncam-common.sh
source "$SCRIPT_DIR/../lib/pigeoncam-common.sh"

PIGEONCAM_LOG_TAG="pigeoncam-setup"

NON_INTERACTIVE=false
ANSWERS_FILE=""
declare -A ANSWERS=()

# Accumulated across the whole run, applied only at the very end (see
# apply_changes) - "only write once all questions are answered, never
# incrementally, so an abandoned run (Ctrl-C, or a validation failure in
# non-interactive mode) changes nothing" per the design spec.
EDIT_KEYS=()
EDIT_VALUES=()
CHANGES=()
STREAM_KEY_FILE_PATH=""
STREAM_KEY_TO_WRITE=""

# Set by ask()/handle_stream_key's callers reading it right after the call -
# see ask()'s own comment for why a single global is fine here (never a
# concurrency concern in a single-threaded script; every caller reads it
# before the next call could overwrite it).
RESOLVED_VALUE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--config PATH] [--non-interactive] [--answers FILE]

Fills in config.yaml by asking a fixed set of questions, editing only the
answered lines in place - every comment, blank line, and untouched key
stays byte-for-byte as it was. Re-runnable: every prompt shows the
current value as its default, so a second run is a review pass, not a
restart. Backs up config.yaml before writing anything.

  --config PATH       config.yaml to edit (default: \$PIGEONCAM_CONFIG, else
                       /etc/pigeoncam/config.yaml). Created from
                       config.example.yaml if it doesn't exist yet.
  --non-interactive   never prompt; every question takes its current value
                       unless --answers overrides it. An unanswerable
                       required question is an error naming the key, never
                       a silent default.
  --answers FILE      key=value lines, one per line ('#' starts a comment,
                       blank lines are ignored). Keys are the same dotted
                       names config.yaml uses (e.g. camera.device=/dev/video0),
                       plus the special key 'stream_key' for the secret
                       written to the stream-key file (never to
                       config.yaml). Implies --non-interactive.

Never enables or starts anything, and never runs pigeoncam-doctor.sh for
you - its output deserves to be read, not scrolled past at the end of a
wizard. Run it yourself as the next step.
EOF
}

# --- in-place YAML line editing --------------------------------------------
# The whole point of this script (see the header comment): every function
# below only ever rewrites the VALUE half of one already-existing line. None
# of them ever add, remove, or reorder a line, so total line count and
# comment-line count are preserved by construction, not by a check
# afterwards.

# file_ends_with_newline <file> - true iff the file's last byte is a
# newline. mapfile silently loses this distinction (every element it reads
# looks the same with -t regardless of whether the source line was
# terminated), so apply_edits below has to track it separately to write the
# file back exactly as it found it - `tail -c1 -- "$1"; echo x` sidesteps
# $(...)'s own trailing-newline stripping by giving it a non-newline
# character to anchor on.
file_ends_with_newline() {
    [[ $(tail -c1 -- "$1"; echo x) == $'\n'x ]]
}

# yaml_find_line <file> <dotted.key> - prints the 1-based line number of
# the line that sets exactly that dotted key. Tracks a small scope stack
# exactly like pigeoncam-doctor.sh's _scan_duplicate_yaml_keys, but
# simpler: this project's config.yaml is known to contain no YAML
# sequences (no `- ` list items anywhere in config.example.yaml), so unlike
# that scanner this one never needs to open a sequence-item scope. Full-path
# tracking (not just "leaf key name at this indentation") is load-bearing,
# not caution for its own sake: config.example.yaml has several leaf keys
# that recur at the same indentation under different parents -
# `youtube.rotation.mode` and `external_check.frame_border.mode` are both a
# bare `mode:` four spaces in, and `enabled:` two spaces in appears under
# half a dozen different blocks - so indentation plus key name alone would
# find the wrong line, silently, for exactly the keys this script edits.
#
# Prints nothing and returns 1 if the key isn't found (the config's
# structure doesn't match config.example.yaml - see apply_edits, which
# treats that as a hard error rather than silently skipping the edit). If
# the key is somehow set more than once, the LAST occurrence wins, matching
# yq's/YAML's own last-one-wins semantics - so editing "the" line for a key
# always edits the line cfg() is actually reading. (A real deployment
# shouldn't have a duplicate in the first place - pigeoncam-doctor.sh's
# check_duplicate_config_keys FAILs the doctor run over exactly that.)
yaml_find_line() {
    local file="$1" want="$2"
    local -a path=() ind=()
    local depth=0 lineno=0 found=0
    local line indent key cur i
    local re_key='^([[:space:]]*)([A-Za-z_][A-Za-z0-9_]*):(.*)$'
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ $re_key ]]; then
            indent=${#BASH_REMATCH[1]}
            key="${BASH_REMATCH[2]}"
            while (( depth > 0 )) && (( ind[depth-1] >= indent )); do
                depth=$((depth-1))
            done
            path[depth]="$key"
            ind[depth]="$indent"
            depth=$((depth+1))
            cur="${path[0]}"
            for (( i=1; i<depth; i++ )); do
                cur+=".${path[i]}"
            done
            [[ "$cur" == "$want" ]] && found=$lineno
        fi
    done < "$file"
    if (( found > 0 )); then
        printf '%d\n' "$found"
        return 0
    fi
    return 1
}

# yaml_dquote_escape <value> - backslash-escapes a value for placement
# inside a YAML double-quoted scalar (backslashes first, then quotes -
# order matters, escaping the quotes first would double-escape the
# backslashes just added). Matters mainly for notify_command: it is the one
# answer here likely to contain a literal double quote (e.g. a
# `curl -d '{"text":"..."}'`-shaped command), and config.example.yaml
# already ships it as `notify_command: ""` (quoted-empty), so
# render_new_line below will write its answer back in quoted style.
yaml_dquote_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

# render_new_line <original_line> <new_value> - returns (on stdout) the
# line with only its value replaced: same indentation, same key, same
# trailing comment (if any, re-attached with a single space rather than
# the original alignment, which was tuned for the old value's length
# anyway), same quoting style as the ORIGINAL line had. Preserving quoting
# style rather than deciding it from the new value's type is deliberate -
# it means this function never has to know or guess config.yaml's
# per-key conventions (why "1920x1080" is quoted but `mjpeg` isn't), it
# just keeps whatever the file already does for that line.
#
# Three cases, tried in order: the original value was double-quoted; the
# original value was a bare (unquoted) single token, the only shape every
# unquoted value in config.example.yaml actually takes (a path, a number, a
# bare word - never multiple words); or - a fallback for a line this
# script didn't write and doesn't expect, e.g. `key:` with nothing after
# it at all (bare YAML null) - anything else, which is re-quoted rather
# than risk emitting something that doesn't round-trip.
render_new_line() {
    local line="$1" new_value="$2"
    local re_quoted='^([[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*)"([^"]*)"(.*)$'
    local re_bare='^([[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*)([^[:space:]#]+)(.*)$'
    local re_any='^([[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*)(.*)$'
    local prefix suffix comment=""

    if [[ "$line" =~ $re_quoted ]]; then
        prefix="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[3]}"
        [[ "$suffix" == *"#"* ]] && comment="#${suffix#*#}"
        printf '%s"%s"%s' "$prefix" "$(yaml_dquote_escape "$new_value")" "${comment:+ $comment}"
        return 0
    fi
    if [[ "$line" =~ $re_bare ]]; then
        prefix="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[3]}"
        [[ "$suffix" == *"#"* ]] && comment="#${suffix#*#}"
        if [[ -z "$new_value" ]]; then
            # An empty value can never be written bare (bare-and-empty is
            # YAML null, a different value than ""), regardless of what the
            # original bare token looked like.
            printf '%s""%s' "$prefix" "${comment:+ $comment}"
        else
            printf '%s%s%s' "$prefix" "$new_value" "${comment:+ $comment}"
        fi
        return 0
    fi
    if [[ "$line" =~ $re_any ]]; then
        prefix="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
        [[ "$suffix" == *"#"* ]] && comment="#${suffix#*#}"
        printf '%s"%s"%s' "$prefix" "$(yaml_dquote_escape "$new_value")" "${comment:+ $comment}"
        return 0
    fi
    log_error "internal error: could not parse the line for key rewriting (this is a bug): $line"
    exit 1
}

# apply_edits - the only place config.yaml is actually rewritten. Resolves
# every EDIT_KEYS[i] to a line number FIRST, against the pristine on-disk
# file, before mutating anything in memory - safe because no edit this
# script makes ever changes a key name or its indentation (only the value
# token), so a line's identity for yaml_find_line's purposes can't shift
# as a result of an earlier edit in this same loop. A no-op (EDIT_KEYS
# empty) still runs the full read/rewrite - see main()'s comment on
# --non-interactive with no --answers, which deliberately reduces to this
# exact path so the write path itself is exercised even when nothing
# changes.
apply_edits() {
    local -a linenos=()
    local key lineno
    for key in "${EDIT_KEYS[@]}"; do
        if ! lineno=$(yaml_find_line "$PIGEONCAM_CONFIG" "$key"); then
            log_error "'$key' was answered, but no line in $PIGEONCAM_CONFIG sets that key - its structure differs from config.example.yaml. Refusing to write anything (nothing has been changed)."
            exit 1
        fi
        linenos+=("$lineno")
    done

    local nl_ending=false
    file_ends_with_newline "$PIGEONCAM_CONFIG" && nl_ending=true
    local -a lines=()
    mapfile -t lines < "$PIGEONCAM_CONFIG"

    local i
    for i in "${!EDIT_KEYS[@]}"; do
        lineno="${linenos[$i]}"
        lines[lineno-1]=$(render_new_line "${lines[lineno-1]}" "${EDIT_VALUES[$i]}")
    done

    local tmp
    tmp=$(mktemp -- "${PIGEONCAM_CONFIG}.XXXXXX")
    {
        local n=${#lines[@]} j
        for (( j=0; j<n; j++ )); do
            if (( j == n-1 )) && ! $nl_ending; then
                printf '%s' "${lines[j]}"
            else
                printf '%s\n' "${lines[j]}"
            fi
        done
    } > "$tmp"
    chmod --reference="$PIGEONCAM_CONFIG" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv -- "$tmp" "$PIGEONCAM_CONFIG"
}

# compute_backup_path - config.yaml.bak-<timestamp>, per the design spec.
# Guards against two runs landing in the same wall-clock second (this
# script's own test suite does exactly that, running the wizard twice in a
# row to check idempotence) by appending a numeric suffix rather than
# silently overwriting an earlier backup from the same second.
compute_backup_path() {
    local base
    base="${PIGEONCAM_CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
    local candidate="$base" n=2
    while [[ -e "$candidate" ]]; do
        candidate="${base}-${n}"
        n=$((n+1))
    done
    printf '%s' "$candidate"
}

# --- --answers file ---------------------------------------------------------

# load_answers <file> - key=value lines into the global ANSWERS map. Splits
# on the FIRST '=' only (a notify_command answer legitimately contains '=',
# e.g. a curl -d 'text=...' payload), and trims whitespace around the key
# only - a value's leading/trailing characters are never silently altered,
# since notify_command's content is meaningful verbatim.
load_answers() {
    local file="$1" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" != *=* ]]; then
            log_error "malformed line in --answers file $file (expected key=value): $line"
            exit 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        ANSWERS["$key"]="$value"
    done < "$file"
}

# --- the generic question driver -------------------------------------------
# ask <dotted.key> <interactive label> <required:true|false> <validator|""> <transform|"">
#
# Resolves one config key's new value (via --answers, an interactive
# prompt, or "keep current" - whichever mode is active), applies an
# optional transform (e.g. building a channel URL from a bare handle) and
# validator, and leaves the result in RESOLVED_VALUE. If the resolved value
# differs from the key's current value in the file, queues it for writing
# in EDIT_KEYS/EDIT_VALUES and records a human-readable line in CHANGES.
# Never writes anything itself - see apply_changes, called only once every
# question (all nine, plus the stream key) has resolved successfully.
ask() {
    local key="$1" label="$2" required="$3" validator="$4" transform="$5"
    local current
    current=$(cfg ".$key" "")
    RESOLVED_VALUE=""
    if $NON_INTERACTIVE; then
        _setup_resolve_noninteractive "$key" "$current" "$required" "$validator" "$transform"
    else
        _setup_prompt_and_validate "$key" "$label" "$current" "$required" "$validator" "$transform"
    fi
    if [[ "$RESOLVED_VALUE" != "$current" ]]; then
        EDIT_KEYS+=("$key")
        EDIT_VALUES+=("$RESOLVED_VALUE")
        CHANGES+=("  $key: '$current' -> '$RESOLVED_VALUE'")
    fi
}

# _setup_resolve_noninteractive - the --non-interactive half of ask().
# Per the design spec: an answer from --answers wins; with no --answers
# entry for this key (including plain --non-interactive with no --answers
# file at all), the key's current value is kept unchanged. An unanswerable
# required question (no current value, and no answer given) is a named
# error, never a silent default - this is what stops a stripped or
# hand-edited config from silently shipping an empty camera.device.
_setup_resolve_noninteractive() {
    local key="$1" current="$2" required="$3" validator="$4" transform="$5"
    local value
    if [[ -n "$ANSWERS_FILE" && -v ANSWERS["$key"] ]]; then
        value="${ANSWERS[$key]}"
    else
        value="$current"
    fi
    if [[ -n "$transform" ]]; then
        value=$("$transform" "$value")
    fi
    if [[ "$required" == true && -z "$value" ]]; then
        log_error "no value for required key '$key' - it has no current value in $PIGEONCAM_CONFIG and none was given (pass $key=<value> in the --answers file)"
        exit 1
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$value"; then
        exit 1   # the validator already printed why, naming the key
    fi
    RESOLVED_VALUE="$value"
}

# _setup_prompt_and_validate - the interactive half of ask(). Loops until a
# valid answer is given: Enter keeps the current value, an invalid answer
# prints why (from the validator) and re-prompts the SAME question rather
# than aborting the whole wizard - non-interactive mode is the one that
# fails fast, since there is nobody there to try again.
_setup_prompt_and_validate() {
    local key="$1" label="$2" current="$3" required="$4" validator="$5" transform="$6"
    local input value
    while true; do
        if ! read -r -p "$label [$current]: " input; then
            echo "" >&2
            log_error "input ended unexpectedly while waiting for an answer to '$key' - aborting, nothing has been written"
            exit 1
        fi
        value="${input:-$current}"
        if [[ -n "$transform" ]]; then
            value=$("$transform" "$value")
        fi
        if [[ "$required" == true && -z "$value" ]]; then
            echo "  a value is required here." >&2
            continue
        fi
        if [[ -n "$validator" ]] && ! "$validator" "$value"; then
            continue
        fi
        break
    done
    RESOLVED_VALUE="$value"
}

# --- validators and transforms ----------------------------------------------
# Each validator prints its own reason (naming the key) to stderr and
# returns non-zero on rejection - ask() relies on that message, it never
# adds its own.

# validate_ingest_url - rejects plain rtmp:// (YouTube requires RTMPS/TLS
# for ingest - a different URL than the one Studio shows by default; click
# the lock icon to reveal it). Empty is caught upstream by the required
# check, not here.
validate_ingest_url() {
    local v="$1"
    if [[ "$v" =~ ^rtmp:// ]]; then
        echo "youtube.ingest_url: '$v' uses plain RTMP - YouTube requires RTMPS (TLS) for ingest. Use the rtmps://... URL from Studio (click the lock icon next to the stream URL to reveal it), e.g. rtmps://a.rtmps.youtube.com/live2" >&2
        return 1
    fi
    return 0
}

# transform_channel_handle - the design spec asks for "the handle" and
# builds the /live URL from it; accepting a full URL too (unchanged, aside
# from the watch?v= check below) makes --answers files flexible without
# needing a second pseudo-key. A leading '@' is optional either way.
transform_channel_handle() {
    local v="$1"
    if [[ -z "$v" || "$v" == *"://"* ]]; then
        printf '%s' "$v"
        return 0
    fi
    v="${v#@}"
    printf 'https://www.youtube.com/@%s/live' "$v"
}

# validate_channel_url - rejects a watch?v=<id> URL: a specific video id
# breaks the moment rotation starts the next broadcast under a different
# id, per the design spec.
validate_channel_url() {
    local v="$1"
    if [[ "$v" == *"watch?v="* ]]; then
        echo "external_check.channel_live_url: '$v' names a specific video id, which breaks on rotation (the next broadcast gets a different id). Use the channel's /live URL instead, e.g. https://www.youtube.com/@yourhandle/live" >&2
        return 1
    fi
    return 0
}

# validate_latitude / validate_longitude - location is optional (the
# design spec is explicit: "Accept empty. Validate ranges. Never guess or
# geolocate."), so empty always passes; a non-empty value is checked with
# the same range validators lib/pigeoncam-solar.sh already uses at
# runtime, so "accepted here" and "accepted by hour_is_daytime/
# check_rotation_due later" can never disagree.
# validate_segment_dir - archive.segment_dir has no default specifically
# so an operator has to choose it deliberately (see the design comment in
# config.example.yaml). The prompt already explains why /var/lib is the
# wrong answer; this is what actually stops it, using the same
# segment_dir_is_durable_state() check pigeoncam-doctor.sh's
# check_archive_dir FAILs on, so "accepted here" and "accepted by doctor"
# can never disagree. Empty is caught upstream by the required check.
validate_segment_dir() {
    local v="$1"
    if [[ -n "$v" ]] && segment_dir_is_durable_state "$v"; then
        echo "archive.segment_dir: '$v' is under $PIGEONCAM_DURABLE_DIR, this project's own state directory - 'apt purge' (and 'make uninstall', by hand) are entitled to erase it. That is exactly what removing this setting's default was meant to prevent. Point it at a data disk or a mount of your own instead (e.g. /srv/pigeoncam/archive)." >&2
        return 1
    fi
    return 0
}

validate_latitude() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    if ! solar_latitude_valid "$v"; then
        echo "location.latitude: '$v' is not a real number in [-90,90]" >&2
        return 1
    fi
    return 0
}

validate_longitude() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    if ! solar_longitude_valid "$v"; then
        echo "location.longitude: '$v' is not a real number in [-180,180]" >&2
        return 1
    fi
    return 0
}

# normalize_bool_yn / validate_bool - youtube_api.enabled's yes/no question.
# Canonicalizes common spellings (y/yes/n/no, and the literal true/false a
# --non-interactive "keep current value" pass already carries) to exactly
# "true"/"false"; validate_bool then rejects anything else. Idempotent by
# construction - the current value read back from config.yaml is already
# canonical, so a re-run's "keep current" pass never flips it.
normalize_bool_yn() {
    local v="${1,,}"
    case "$v" in
        y|yes|true|1) printf 'true' ;;
        n|no|false|0) printf 'false' ;;
        *) printf '%s' "$1" ;;   # pass through unrecognized input; validate_bool rejects it
    esac
}

validate_bool() {
    case "$1" in
        true|false) return 0 ;;
        *) echo "youtube_api.enabled: '$1' is not true/false (yes/no also accepted)" >&2; return 1 ;;
    esac
}

# --- advisory, non-blocking warnings ----------------------------------------
# None of these reject an answer - they print a heads-up and let the
# wizard continue, the same "advisory, not enforced" stance
# pigeoncam-doctor.sh already takes for storage sizing and the rotation
# interval ceiling.

warn_if_device_missing() {
    local device="$1"
    if [[ ! -e "$device" ]]; then
        echo "  note: $device does not exist yet. That's fine if the udev rule for your camera isn't in place yet - see $PIGEONCAM_DOC_DIR/udev/99-pigeoncam.rules.example - but the camera won't work until it does."
    fi
}

# warn_if_yuyv_1080p - the design spec's "never offer a YUYV mode at 1080p
# without repeating the silent-5fps warning", applied to whatever the
# final format+resolution answers are, however they were obtained
# (interactive pick, --answers, or kept unchanged) - not just to an
# interactive listing, so the warning can't be skipped by answering
# non-interactively. Matches README's "Known gotchas" wording for the same
# trap.
warn_if_yuyv_1080p() {
    local fmt="$1" res="$2"
    if [[ "${fmt,,}" == "yuyv" && "$res" == *1080* ]]; then
        echo "  warning: YUYV at $res is a known trap - some cameras only offer this combination at a crippled ~5fps (the format and the resolution each exist, just not together with a usable frame rate over USB 2.0). Prefer input_format: mjpeg at this resolution - see $PIGEONCAM_DOC_DIR/docs/TROUBLESHOOTING.md."
    fi
}

# warn_disk_headroom - Q6's "warn if the filesystem has less headroom than
# pigeoncam-doctor.sh's own estimate for the answers given so far" -
# daily_archive_gb (lib/pigeoncam-common.sh) is that exact estimate, using
# the encode/retention settings currently in the config (not asked here)
# against the just-answered segment_dir. Best-effort throughout: an
# unparseable daytime window, a df failure, or a not-yet-existing directory
# tree all just skip the warning rather than block the wizard - the same
# "advisory, never blocking" contract as pigeoncam-doctor.sh's own
# check_archive_disk_space.
warn_disk_headroom() {
    local dir="$1" probe_dir gb_per_day avail_kb
    cfg_bool '.archive.enabled' true || return 0

    probe_dir="$dir"
    while [[ ! -d "$probe_dir" && "$probe_dir" != "/" ]]; do
        probe_dir=$(dirname -- "$probe_dir")
    done
    [[ -d "$probe_dir" ]] || return 0

    gb_per_day=$(daily_archive_gb) || return 0
    avail_kb=$(df -Pk -- "$probe_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ -n "$avail_kb" ]] || return 0

    awk -v kb="$avail_kb" -v daily="$gb_per_day" -v dir="$dir" '
        BEGIN {
            avail_gb = kb / 1e6
            days_left = (daily > 0) ? avail_gb / daily : 999999
            if (days_left < 7) {
                printf "  warning: only ~%.1f day(s) of headroom on the filesystem holding %s at the current encode/retention settings (~%.2f GB/day, ~%.1f GB free) - see pigeoncam-doctor.sh for the full sizing estimate.\n", days_left, dir, daily, avail_gb
            }
        }
    '
}

# --- stream key (never a config.yaml value - see the design spec's Q4) -----

# write_stream_key_file <path> <secret> - mode 600 from the moment the file
# has content, not as an afterthought: umask 077 for the write itself, then
# chmod 600 again unconditionally afterward so the final permission never
# depends on the umask the wizard happened to be run under.
# Every step checked and propagated: apply_changes below reports and
# aborts on failure rather than claiming success, and callers can only do
# that if this function's own return status is trustworthy.
write_stream_key_file() {
    local key_file="$1" secret="$2"
    mkdir -p -- "$(dirname -- "$key_file")" || return 1
    ( umask 077; printf '%s\n' "$secret" > "$key_file" ) || return 1
    chmod 600 -- "$key_file" || return 1
}

# handle_stream_key - not built on the generic ask() driver: the secret has
# no config.yaml representation to read a "current value" from (by design -
# "never into config.yaml"), so "current" here means "does the file already
# exist", not a YAML value. Sets STREAM_KEY_TO_WRITE (empty = nothing to
# write) and STREAM_KEY_FILE_PATH for apply_changes.
#
# Non-interactive: an explicit (non-empty) --answers stream_key= always
# writes/replaces. With no answer, an existing file is left alone (per the
# design spec: "Skip if the file already exists, unless the operator asks
# to replace it"); a MISSING file with no answer is the same "unanswerable
# required question" the other eight questions apply - a stream that can't
# authenticate isn't a deployment this wizard should quietly call finished.
#
# Interactive: an existing file prompts to replace it (default no, so
# repeated re-runs of the wizard don't re-ask for a secret already in
# place); a missing one prompts for it twice (hidden input) and requires
# the two entries to match, since a typo here fails silently at stream
# start with nothing more specific than "authentication failed".
handle_stream_key() {
    local key_file
    key_file=$(cfg '.youtube.stream_key_file' /etc/pigeoncam/stream_key)
    STREAM_KEY_FILE_PATH="$key_file"
    STREAM_KEY_TO_WRITE=""

    if $NON_INTERACTIVE; then
        if [[ -n "$ANSWERS_FILE" && -v ANSWERS[stream_key] ]]; then
            local secret="${ANSWERS[stream_key]}"
            if [[ -z "$secret" ]]; then
                log_error "no value for required key 'stream_key' (given but empty in --answers)"
                exit 1
            fi
            STREAM_KEY_TO_WRITE="$secret"
            CHANGES+=("  stream key file: written to $key_file")
        elif [[ ! -f "$key_file" ]]; then
            log_error "no value for required key 'stream_key' - the stream key file $key_file does not exist yet, and none was given (pass stream_key=<key> in the --answers file)"
            exit 1
        fi
        return 0
    fi

    if [[ -f "$key_file" ]]; then
        local yn
        if ! read -r -p "Stream key file already exists at $key_file. Replace it? [y/N]: " yn; then
            echo "" >&2
            return 0
        fi
        case "${yn,,}" in
            y|yes) ;;
            *) return 0 ;;
        esac
    fi

    local secret1 secret2
    while true; do
        if ! read -rs -p "YouTube stream key (input hidden): " secret1; then
            echo "" >&2
            log_error "input ended unexpectedly while waiting for the stream key - aborting, nothing has been written"
            exit 1
        fi
        echo ""
        if [[ -z "$secret1" ]]; then
            echo "  a value is required here." >&2
            continue
        fi
        read -rs -p "Re-enter to confirm: " secret2 || secret2=""
        echo ""
        if [[ "$secret1" != "$secret2" ]]; then
            echo "  did not match - try again." >&2
            continue
        fi
        break
    done
    STREAM_KEY_TO_WRITE="$secret1"
    CHANGES+=("  stream key file: written to $key_file")
}

# --- config existence (design spec: "If that file does not exist, offer
#     to create it from config.example.yaml and continue.") ----------------
ensure_config_exists() {
    [[ -f "$PIGEONCAM_CONFIG" ]] && return 0

    local example="$PIGEONCAM_PROJECT_ROOT/config.example.yaml"
    if [[ ! -f "$example" ]]; then
        log_error "config file not found at $PIGEONCAM_CONFIG, and the reference template $example is also missing - cannot continue"
        exit 1
    fi

    if ! $NON_INTERACTIVE; then
        local yn
        if ! read -r -p "$PIGEONCAM_CONFIG does not exist yet. Create it from $example now? [Y/n]: " yn; then
            echo "" >&2
            log_error "input ended unexpectedly - cannot continue without a config file"
            exit 1
        fi
        case "${yn,,}" in
            n|no)
                log_error "cannot continue without a config file"
                exit 1
                ;;
        esac
    fi

    if ! mkdir -p -- "$(dirname -- "$PIGEONCAM_CONFIG")"; then
        log_error "could not create the directory for $PIGEONCAM_CONFIG - check permissions on its parent"
        exit 1
    fi
    if ! cp -- "$example" "$PIGEONCAM_CONFIG"; then
        log_error "could not copy $example to $PIGEONCAM_CONFIG - check permissions"
        exit 1
    fi
    echo "Created $PIGEONCAM_CONFIG from $example."
}

# --- Q8's test notification, and Q9's YouTube API next steps --------------

# offer_test_notification <resolved notify_command> - interactive-only
# convenience (design spec: "Offer to send a test notification if one is
# given"); a no-op in non-interactive mode, since there is nobody to ask.
# Sends via the resolved value directly, not notify_escalation() from
# lib/pigeoncam-common.sh - that helper reads notify_command from
# config.yaml, which has not been written yet at this point in the run
# (writes only happen once every question has been answered).
offer_test_notification() {
    local cmd="$1"
    $NON_INTERACTIVE && return 0
    [[ -n "$cmd" ]] || return 0

    local yn
    read -r -p "Send a test notification now using this command? [y/N]: " yn || yn=""
    case "${yn,,}" in
        y|yes) ;;
        *) return 0 ;;
    esac

    echo "Sending a test notification..."
    local out
    if out=$(timeout 10 sh -c "$cmd" sh TEST "this is a test notification from pigeoncam-setup.sh" 2>&1); then
        echo "  sent (command exited 0)."
    else
        echo "  the command failed or timed out: ${out:-no output}" >&2
    fi
}

# print_youtube_api_next_steps - design spec's Q9: "On yes, do not attempt
# the OAuth flow - print the two commands from docs/YOUTUBE-API.md and
# continue." The one-time --authorize command needs a real browser
# round-trip (or an SSH tunnel) and the operator's own Google Cloud
# Console setup, neither of which this script can do on someone's behalf.
#
# The venv step is conditional, not always printed: a package install's
# postinst now attempts that venv unconditionally and best-effort (see
# docs/development/design/debian-packaging.md item 2), so by the time
# this script runs it may already be there - printing a redundant "create
# the venv" step in that case would be actively confusing, not just
# unnecessary. youtube_api_venv_functional() (lib/pigeoncam-common.sh) is
# the same real-imports check pigeoncam-doctor.sh's check_youtube_api
# uses, not just "does the interpreter exist" - a venv postinst started
# but couldn't finish (network died mid-pip-install) has a working
# interpreter with missing dependencies, and this must not tell the
# operator that is "ready".
print_youtube_api_next_steps() {
    echo ""
    echo "YouTube API access requested. This script does not run the sign-in flow for you - do that yourself:"
    if youtube_api_venv_functional; then
        echo "  1. sudo PIGEONCAM_CONFIG=$PIGEONCAM_CONFIG $PIGEONCAM_VENV_DIR/bin/python3 $PIGEONCAM_PROJECT_ROOT/api/rotate_via_api.py --authorize"
    else
        echo "  1. sudo apt install -y python3-venv && sudo python3 -m venv $PIGEONCAM_VENV_DIR && sudo $PIGEONCAM_VENV_DIR/bin/pip install -r $PIGEONCAM_PROJECT_ROOT/api/requirements.txt"
        echo "  2. sudo PIGEONCAM_CONFIG=$PIGEONCAM_CONFIG $PIGEONCAM_VENV_DIR/bin/python3 $PIGEONCAM_PROJECT_ROOT/api/rotate_via_api.py --authorize"
    fi
    echo "Full walkthrough (Google Cloud Console setup, finding your persistent stream id): $PIGEONCAM_DOC_DIR/docs/YOUTUBE-API.md"
}

# --- final write ------------------------------------------------------------

# apply_changes - the only place anything is actually written, and only
# ever reached after every question above has already resolved and
# validated successfully. Backs up first (unconditionally - even a run
# where nothing changed still "exercises the write path", per the design
# spec, which a skipped backup would not), then the stream key file if one
# was collected, then edits config.yaml in place, then prints a summary:
# what changed, where the backup went, and pigeoncam-doctor.sh as the next
# step - never run automatically, and nothing here ever touches systemd.
#
# Stream key BEFORE config.yaml, deliberately: they are two independent
# writes to two different files with nothing to roll back if one succeeds
# and the other doesn't, so the ordering is what decides how badly a
# mid-write failure lands. This way, a failure writing the key (bad
# permissions on its parent, a full disk) leaves config.yaml exactly as the
# backup does - not silently missing the 8 other answers this run also
# collected because they happened to apply first.
apply_changes() {
    local backup
    backup=$(compute_backup_path)
    if ! cp -p -- "$PIGEONCAM_CONFIG" "$backup"; then
        log_error "could not write backup to $backup - aborting before touching $PIGEONCAM_CONFIG"
        exit 1
    fi

    if [[ -n "$STREAM_KEY_TO_WRITE" ]]; then
        if ! write_stream_key_file "$STREAM_KEY_FILE_PATH" "$STREAM_KEY_TO_WRITE"; then
            log_error "could not write the stream key to $STREAM_KEY_FILE_PATH (check permissions on its parent directory) - nothing else has been changed. Fix the problem and re-run; this script is safe to re-run."
            exit 1
        fi
    fi

    apply_edits

    echo ""
    echo "Changes:"
    if (( ${#CHANGES[@]} == 0 )); then
        echo "  (nothing changed)"
    else
        printf '%s\n' "${CHANGES[@]}"
    fi
    echo ""
    echo "Backup written to $backup"
    echo ""
    echo "Next: run $PIGEONCAM_PROJECT_ROOT/bin/pigeoncam-doctor.sh and fix anything it reports. Nothing has been enabled or started."
}

# --- the nine questions, in the design spec's order -------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                [[ $# -ge 2 ]] || { echo "--config needs a PATH argument" >&2; usage >&2; exit 2; }
                PIGEONCAM_CONFIG="$2"; shift 2 ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            --answers)
                [[ $# -ge 2 ]] || { echo "--answers needs a FILE argument" >&2; usage >&2; exit 2; }
                ANSWERS_FILE="$2"; NON_INTERACTIVE=true; shift 2 ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "unknown argument: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    require_cmd yq jq

    if [[ -n "$ANSWERS_FILE" ]]; then
        if [[ ! -f "$ANSWERS_FILE" ]]; then
            log_error "--answers file not found: $ANSWERS_FILE"
            exit 1
        fi
        load_answers "$ANSWERS_FILE"
    fi

    ensure_config_exists

    echo "Editing $PIGEONCAM_CONFIG"
    if ! $NON_INTERACTIVE; then
        echo "Every prompt shows the current value in [brackets] - press Enter to keep it."
    fi
    echo ""

    # Q1: camera.device
    if ! $NON_INTERACTIVE && command -v v4l2-ctl >/dev/null 2>&1; then
        echo "Detected video devices (v4l2-ctl --list-devices):"
        v4l2-ctl --list-devices 2>/dev/null | sed 's/^/  /'
        echo ""
    fi
    ask camera.device "Camera device (the stable udev symlink, not /dev/videoN)" true "" ""
    local device_answer="$RESOLVED_VALUE"
    warn_if_device_missing "$device_answer"

    # Q2: camera.input_format, camera.resolution, camera.framerate
    if ! $NON_INTERACTIVE && [[ -e "$device_answer" ]] && command -v v4l2-ctl >/dev/null 2>&1; then
        echo "Modes this device reports (v4l2-ctl --list-formats-ext):"
        v4l2-ctl --list-formats-ext -d "$device_answer" 2>/dev/null | sed 's/^/  /'
        echo "(YUYV at 1920x1080 is often capped to ~5fps - see the warning below if you pick it.)"
        echo ""
    fi
    ask camera.input_format "Capture format (mjpeg recommended - see docs/TROUBLESHOOTING.md before choosing yuyv)" true "" ""
    local fmt_answer="$RESOLVED_VALUE"
    ask camera.resolution "Resolution, e.g. 1920x1080" true "" ""
    local res_answer="$RESOLVED_VALUE"
    ask camera.framerate "Frame rate, e.g. 30" true "" ""
    warn_if_yuyv_1080p "$fmt_answer" "$res_answer"

    # Q3: youtube.ingest_url
    ask youtube.ingest_url "YouTube RTMPS ingest URL" true validate_ingest_url ""

    # Q4: stream key (never written to config.yaml - see handle_stream_key)
    handle_stream_key

    # Q5: external_check.channel_live_url
    ask external_check.channel_live_url "YouTube channel handle (e.g. yourhandle) or full .../live URL" true validate_channel_url transform_channel_handle

    # Q6: archive.segment_dir. Required, and shipped empty - there is no
    # default to fall back on, deliberately (see the config comment). Say
    # why before asking, since "required with no default" is otherwise just
    # an obstacle: the operator is being asked to make a real decision
    # about where irreplaceable footage lives, and it is worth one line to
    # tell them that is what this is.
    if ! $NON_INTERACTIVE && [[ -z "$(cfg '.archive.segment_dir' '')" ]]; then
        echo ""
        echo "Where should local recordings go? There is no default on purpose: this is your data, it is tens of GB per day at the settings above, and the right filesystem is the one on THIS machine with the room. Do not put it under /var/lib - that is program state, and uninstalling the package may erase it. A data disk or a mount of your own (e.g. /srv/pigeoncam/archive) is what you want. Set archive.enabled: false in the config if you don't want local recording at all."
    fi
    ask archive.segment_dir "Local archive directory" true validate_segment_dir ""
    warn_disk_headroom "$RESOLVED_VALUE"

    # Q7: location.latitude, location.longitude (optional)
    if ! $NON_INTERACTIVE; then
        echo ""
        echo "Location is optional - it enables solar-relative scheduling (rotation centred on solar noon, and a daytime window that shrinks and grows with the season) instead of the fixed-clock defaults. Leave both empty to skip."
    fi
    ask location.latitude "Latitude in decimal degrees, e.g. 48.8566 (optional)" false validate_latitude ""
    ask location.longitude "Longitude in decimal degrees, e.g. 2.3522 (optional)" false validate_longitude ""

    # Q8: notify_command (optional, actively encouraged)
    if ! $NON_INTERACTIVE; then
        echo ""
        echo "notify_command is optional but strongly encouraged - leaving it empty means every alert this system raises (a health check going blind, a failing rotation, a unit that won't start) reaches only the system journal. A full season ran that way here before anyone noticed a blind health check."
    fi
    ask notify_command 'Notification command (optional; runs as: sh -c "$notify_command" sh LABEL MESSAGE)' false "" ""
    offer_test_notification "$RESOLVED_VALUE"

    # Q9: youtube_api.enabled
    ask youtube_api.enabled "Enable YouTube API access, for cleaner rotation and automatic stuck-broadcast recovery? (y/n)" true validate_bool normalize_bool_yn
    if [[ "$RESOLVED_VALUE" == true ]]; then
        print_youtube_api_next_steps
    fi

    apply_changes
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Bare on purpose - main() never falls off the end with a bare nonzero
    # status; every exit above is explicit. See the matching note in
    # bin/pigeoncam-doctor.sh/pigeoncam-ctl.sh for why `main "$@" || exit $?`
    # must never be used here instead: it would disable set -e for main and
    # everything it calls, recursively.
    main "$@"
fi

#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_setup.sh - bin/pigeoncam-setup.sh, per the "## Tests" section of
# docs/development/design/setup-script.md. Every scenario drives the real
# script via --non-interactive --answers against a real copy of the real
# config.example.yaml, per that spec: "All via --non-interactive --answers,
# against a temp config." Comments below say which numbered test in that
# section a block of assertions maps to.
#
# Deliberately never lets youtube.stream_key_file resolve to the real
# /etc/pigeoncam/stream_key - config.example.yaml's shipped default is
# exactly that real system path (a package's postinst installs there for
# real), so every fixture config here has it redirected into $WORK first
# (make_base_config below). The one scenario that intentionally leaves it
# untouched (test 9, a config freshly created from config.example.yaml)
# never reaches a write to that path, and asserts only what holds on any
# host - see that scenario's own comment for the trap it used to fall into.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_setup.sh ==="

SETUP="$REPO_ROOT/bin/pigeoncam-setup.sh"
EXAMPLE="$REPO_ROOT/config.example.yaml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

comment_count() { grep -cE '^[[:space:]]*#' -- "$1"; }
line_count() { wc -l < "$1"; }

# Read from the shipped file rather than hardcoded, so editing
# config.example.yaml never makes this suite fail for a reason that has
# nothing to do with the wizard. The property under test is "the wizard
# preserves what was there", which is a comparison, not a constant - a
# literal count only ever measured how recently someone updated the test.
EXAMPLE_COMMENTS=$(comment_count "$EXAMPLE")
# The counts are derived, so guard the thing the old literal was really
# protecting: that config.example.yaml still carries its documentation at
# all. Those comments are where every non-obvious default is explained,
# and a change that quietly gutted them would otherwise sail through.
assert_true "config.example.yaml still carries its inline documentation (>300 comment lines)" \
    [ "$EXAMPLE_COMMENTS" -gt 300 ]

# make_base_config <dest> <keyfile> - a fresh copy of the real
# config.example.yaml with ONLY youtube.stream_key_file redirected (a
# literal, unique text substitution - config.example.yaml names that real
# path exactly once, confirmed) so no scenario here can ever write to the
# real /etc/pigeoncam, regardless of what the operator running this suite
# has installed. Every other line is byte-for-byte what ships in the repo.
make_base_config() {
    local dest="$1" keyfile="$2"
    cp -- "$EXAMPLE" "$dest"
    sed -i "s#/etc/pigeoncam/stream_key#$keyfile#" "$dest"
    # archive.segment_dir ships empty and is required whenever archiving is
    # on, so a fixture standing in for "a config an operator already runs"
    # has to have chosen one. Inside $WORK, never a real path - the same
    # reasoning as the key file above, and doubly so here, since this is the
    # setting that decides where tens of GB a day get written.
    sed -i "s#^\(  segment_dir: \)\"\"#\1\"$(dirname -- "$dest")/base-archive\"#" "$dest"
}

# write_good_answers <dest> <segment_dir> - one baseline --answers file
# reused (with small overrides) across most scenarios. Deliberately
# answers camera.input_format and youtube.ingest_url with the SAME value
# config.example.yaml already ships, and youtube_api.enabled with its
# already-false default spelled as "no" - alongside the keys that DO
# change, this is what lets test 2 assert the diff shows exactly the
# changed keys and nothing else: an answer identical to the current value
# must never appear as a change.
write_good_answers() {
    local dest="$1" segdir="$2"
    cat > "$dest" <<'EOF'
camera.device=/dev/video7
camera.input_format=mjpeg
camera.resolution=1280x720
camera.framerate=25
youtube.ingest_url=rtmps://a.rtmps.youtube.com/live2
stream_key=SUPER-SECRET-KEY-123
external_check.channel_live_url=examplehandle
location.latitude=48.8566
location.longitude=2.3522
notify_command=/usr/local/bin/notify "$1" "$2"
youtube_api.enabled=no
EOF
    echo "archive.segment_dir=$segdir" >> "$dest"
}

run_setup() {
    "$SETUP" --config "$1" --non-interactive --answers "$2"
}

# =====================================================================
# tests 1 + 2: comments/line count survive, and the diff shows exactly
# the answered (and actually-changed) keys - nothing else.
# =====================================================================
S1="$WORK/s1"; mkdir -p "$S1"
CONFIG1="$S1/config.yaml"
make_base_config "$CONFIG1" "$S1/stream_key"
BEFORE1="$S1/before.yaml"
cp -- "$CONFIG1" "$BEFORE1"
ANSWERS1="$S1/answers.txt"
write_good_answers "$ANSWERS1" "$S1/archive"

out1=$(run_setup "$CONFIG1" "$ANSWERS1" 2>&1)
rc1=$?
assert_eq "0" "$rc1" "test 1/2: a fully-answered non-interactive run exits 0"

assert_eq "$(comment_count "$BEFORE1")" "$(comment_count "$CONFIG1")" \
    "test 1 (headline): comment-line count is unchanged after the run"
assert_eq "$EXAMPLE_COMMENTS" "$(comment_count "$CONFIG1")" \
    "test 1: comment count still matches config.example.yaml exactly"
assert_eq "$(line_count "$BEFORE1")" "$(line_count "$CONFIG1")" \
    "test 1: total line count is unchanged after the run"

diff1=$(diff "$BEFORE1" "$CONFIG1" || true)
changed1=$(grep -c '^<' <<<"$diff1")
assert_eq "8" "$changed1" \
    "test 2: exactly 8 lines changed (the 8 keys whose answer differs from the shipped default)"
assert_contains "$diff1" "device: /dev/video7" "test 2: camera.device's new value is in the diff"
assert_contains "$(grep 'device:' "$CONFIG1")" "stable udev symlink" \
    "test 2: the edited camera.device line keeps its own trailing comment (only the value token changed)"
assert_contains "$diff1" 'resolution: "1280x720"' "test 2: camera.resolution's new value is in the diff (quoting style preserved)"
assert_contains "$diff1" "framerate: 25" "test 2: camera.framerate's new value is in the diff"
assert_contains "$diff1" 'channel_live_url: "https://www.youtube.com/@examplehandle/live"' \
    "test 2: external_check.channel_live_url built from the bare handle answer is in the diff"
assert_contains "$diff1" "segment_dir: \"$S1/archive\"" \
    "test 2: archive.segment_dir's new value is in the diff (quoted, because the line it replaced was)"
assert_contains "$diff1" 'latitude: "48.8566"' "test 2: location.latitude's new value is in the diff"
assert_contains "$diff1" 'longitude: "2.3522"' "test 2: location.longitude's new value is in the diff"
assert_contains "$diff1" 'notify_command: "/usr/local/bin/notify \"$1\" \"$2\""' \
    "test 2: notify_command's new value is in the diff, with embedded quotes correctly YAML-escaped"
assert_not_contains "$diff1" "input_format" \
    "test 2: camera.input_format was answered identically to its default and does NOT appear as a change"
assert_not_contains "$diff1" "ingest_url" \
    "test 2: youtube.ingest_url was answered identically to its default and does NOT appear as a change"
assert_not_contains "$diff1" "youtube_api" \
    "test 2: youtube_api.enabled normalized to its already-current value and does NOT appear as a change"
assert_not_contains "$diff1" "SUPER-SECRET-KEY" \
    "the stream key never appears in the config diff at all (it has no config.yaml line to change)"

# The escaping round-trips through the REAL yq, not just a text match -
# confirms notify_command reads back as the exact raw command, quotes and
# all, not as something subtly mis-escaped that merely looks right in a
# text diff.
notify_roundtrip=$(yq -r '.notify_command' "$CONFIG1")
assert_eq '/usr/local/bin/notify "$1" "$2"' "$notify_roundtrip" \
    "notify_command round-trips through real yq as the exact raw command"

# =====================================================================
# test 3: idempotent - running twice with the same answers produces a
# file identical to running once.
# =====================================================================
S3="$WORK/s3"; mkdir -p "$S3"
CONFIG3="$S3/config.yaml"
make_base_config "$CONFIG3" "$S3/stream_key"
ANSWERS3="$S3/answers.txt"
write_good_answers "$ANSWERS3" "$S3/archive"

run_setup "$CONFIG3" "$ANSWERS3" >/dev/null 2>&1
AFTER_RUN1="$S3/after-run1.yaml"
cp -- "$CONFIG3" "$AFTER_RUN1"
run_setup "$CONFIG3" "$ANSWERS3" >/dev/null 2>&1
assert_eq "" "$(diff "$AFTER_RUN1" "$CONFIG3" || true)" \
    "test 3: running the same --answers twice produces a byte-identical result"

# =====================================================================
# test 4: Enter (no answer for a key) keeps the current value exactly -
# combined here with the stream-key-file-already-exists skip path, since
# both are the same underlying idea applied to config.yaml vs. the
# separate key file.
# =====================================================================
S4="$WORK/s4"; mkdir -p "$S4"
CONFIG4="$S4/config.yaml"
KEYFILE4="$S4/stream_key"
make_base_config "$CONFIG4" "$KEYFILE4"
BEFORE4="$S4/before.yaml"
cp -- "$CONFIG4" "$BEFORE4"
printf 'pre-existing-key-do-not-touch\n' > "$KEYFILE4"
chmod 600 "$KEYFILE4"
KEYFILE4_BEFORE="$S4/keyfile-before.txt"
cp -- "$KEYFILE4" "$KEYFILE4_BEFORE"

ANSWERS4="$S4/answers.txt"
printf 'camera.device=/dev/video9\n' > "$ANSWERS4"
out4=$(run_setup "$CONFIG4" "$ANSWERS4" 2>&1)
rc4=$?
assert_eq "0" "$rc4" "test 4: a single-key answers file (no stream_key answer) still succeeds because the key file already exists"

diff4=$(diff "$BEFORE4" "$CONFIG4" || true)
changed4=$(grep -c '^<' <<<"$diff4")
assert_eq "1" "$changed4" "test 4: only the one answered line changed"
assert_contains "$diff4" "device: /dev/video9" "test 4: the answered key (camera.device) did change"

assert_eq "" "$(diff "$KEYFILE4_BEFORE" "$KEYFILE4" || true)" \
    "test 4 / design spec Q4: an existing stream key file is left untouched when no answer is given for it"
assert_not_contains "$out4" "stream key file: written" \
    "test 4: the summary does not claim the stream key changed when it was skipped (only camera.device should be listed)"

# =====================================================================
# test 5: the stream key never lands in config.yaml, does land in its
# own file, and that file is mode 600 - plus: an explicit answer REPLACES
# an existing key file rather than skipping it.
# =====================================================================
S5="$WORK/s5"; mkdir -p "$S5"
CONFIG5="$S5/config.yaml"
KEYFILE5="$S5/stream_key"
make_base_config "$CONFIG5" "$KEYFILE5"
ANSWERS5="$S5/answers.txt"
write_good_answers "$ANSWERS5" "$S5/archive"

run_setup "$CONFIG5" "$ANSWERS5" >/dev/null 2>&1
assert_not_contains "$(cat "$CONFIG5")" "SUPER-SECRET-KEY-123" \
    "test 5: the stream key text does not appear anywhere in config.yaml"
assert_file_exists "$KEYFILE5" "test 5: the stream key file was created at youtube.stream_key_file's path"
assert_eq "SUPER-SECRET-KEY-123" "$(cat "$KEYFILE5")" "test 5: the stream key file's content is exactly the given key"
assert_eq "600" "$(stat -c '%a' -- "$KEYFILE5")" "test 5: the stream key file is mode 600"

# An explicit stream_key answer replaces an existing file - the "skip"
# behaviour in the design spec is conditioned on "no answer given", not
# on "the file already exists" unconditionally.
ANSWERS5B="$S5/answers-replace.txt"
sed 's/SUPER-SECRET-KEY-123/REPLACED-KEY-456/' "$ANSWERS5" > "$ANSWERS5B"
run_setup "$CONFIG5" "$ANSWERS5B" >/dev/null 2>&1
assert_eq "REPLACED-KEY-456" "$(cat "$KEYFILE5")" \
    "test 5: an explicit stream_key answer replaces an existing key file's content"
assert_eq "600" "$(stat -c '%a' -- "$KEYFILE5")" "test 5: the replaced stream key file is still mode 600"

# =====================================================================
# test 6: validation rejects rtmp://, a watch?v= channel URL, and an
# out-of-range latitude, each naming the reason. Each sub-case starts
# from the SAME valid baseline with exactly one field corrupted, so the
# run is guaranteed to reach (and fail at) the intended question
# regardless of the fixed question order.
# =====================================================================
make_bad_answers() { # make_bad_answers <dest> <segdir> <bad_key> <bad_value>
    local dest="$1" segdir="$2" bad_key="$3" bad_value="$4"
    write_good_answers "$dest" "$segdir"
    # Escape sed metacharacters in the replacement (the URLs below contain
    # '/' and '?', both special to sed's default '/'-delimited s///).
    local esc_value=${bad_value//\\/\\\\}
    esc_value=${esc_value//#/\\#}
    sed -i "s#^${bad_key}=.*#${bad_key}=${esc_value}#" "$dest"
}

# --- 6a: rtmp:// (not rtmps://) ---
S6A="$WORK/s6a"; mkdir -p "$S6A"
CONFIG6A="$S6A/config.yaml"
make_base_config "$CONFIG6A" "$S6A/stream_key"
BEFORE6A="$S6A/before.yaml"; cp -- "$CONFIG6A" "$BEFORE6A"
ANSWERS6A="$S6A/answers.txt"
make_bad_answers "$ANSWERS6A" "$S6A/archive" "youtube.ingest_url" "rtmp://a.rtmps.youtube.com/live2"
err6a=$(run_setup "$CONFIG6A" "$ANSWERS6A" 2>&1 1>/dev/null)
rc6a=$?
assert_true "test 6a: a plain rtmp:// ingest URL is rejected (non-zero exit)" bash -c "[ '$rc6a' -ne 0 ]"
assert_contains "$err6a" "youtube.ingest_url" "test 6a: the error names the key"
assert_contains "$err6a" "RTMP" "test 6a: the error names the reason (plain RTMP vs RTMPS)"
assert_eq "" "$(diff "$BEFORE6A" "$CONFIG6A" || true)" "test 6a: a rejected answer leaves config.yaml byte-identical"

# --- 6b: watch?v=<id> channel URL ---
S6B="$WORK/s6b"; mkdir -p "$S6B"
CONFIG6B="$S6B/config.yaml"
make_base_config "$CONFIG6B" "$S6B/stream_key"
BEFORE6B="$S6B/before.yaml"; cp -- "$CONFIG6B" "$BEFORE6B"
ANSWERS6B="$S6B/answers.txt"
make_bad_answers "$ANSWERS6B" "$S6B/archive" "external_check.channel_live_url" "https://www.youtube.com/watch?v=abc123XYZ"
err6b=$(run_setup "$CONFIG6B" "$ANSWERS6B" 2>&1 1>/dev/null)
rc6b=$?
assert_true "test 6b: a watch?v= channel URL is rejected (non-zero exit)" bash -c "[ '$rc6b' -ne 0 ]"
assert_contains "$err6b" "external_check.channel_live_url" "test 6b: the error names the key"
assert_contains "$err6b" "watch?v=" "test 6b: the error names the reason (a specific video id)"
assert_eq "" "$(diff "$BEFORE6B" "$CONFIG6B" || true)" "test 6b: a rejected answer leaves config.yaml byte-identical"

# --- 6c: out-of-range latitude ---
S6C="$WORK/s6c"; mkdir -p "$S6C"
CONFIG6C="$S6C/config.yaml"
make_base_config "$CONFIG6C" "$S6C/stream_key"
BEFORE6C="$S6C/before.yaml"; cp -- "$CONFIG6C" "$BEFORE6C"
ANSWERS6C="$S6C/answers.txt"
make_bad_answers "$ANSWERS6C" "$S6C/archive" "location.latitude" "999"
err6c=$(run_setup "$CONFIG6C" "$ANSWERS6C" 2>&1 1>/dev/null)
rc6c=$?
assert_true "test 6c: an out-of-range latitude is rejected (non-zero exit)" bash -c "[ '$rc6c' -ne 0 ]"
assert_contains "$err6c" "location.latitude" "test 6c: the error names the key"
assert_contains "$err6c" "[-90,90]" "test 6c: the error names the reason (the valid range)"
assert_eq "" "$(diff "$BEFORE6C" "$CONFIG6C" || true)" "test 6c: a rejected answer leaves config.yaml byte-identical"

# =====================================================================
# test 7: a backup is written, and its content equals the pre-run file.
# =====================================================================
S7="$WORK/s7"; mkdir -p "$S7"
CONFIG7="$S7/config.yaml"
make_base_config "$CONFIG7" "$S7/stream_key"
BEFORE7="$S7/before.yaml"
cp -- "$CONFIG7" "$BEFORE7"
ANSWERS7="$S7/answers.txt"
write_good_answers "$ANSWERS7" "$S7/archive"

run_setup "$CONFIG7" "$ANSWERS7" >/dev/null 2>&1
mapfile -t backups7 < <(find "$S7" -maxdepth 1 -name 'config.yaml.bak-*' | sort)
assert_eq "1" "${#backups7[@]}" "test 7: exactly one backup file was written"
if (( ${#backups7[@]} > 0 )); then
    assert_eq "" "$(diff "$BEFORE7" "${backups7[0]}" || true)" \
        "test 7: the backup's content equals the pre-run file exactly"
fi

# =====================================================================
# test 8: abandoning changes nothing - a run that fails validation in
# non-interactive mode leaves the config byte-identical. (Mechanically
# the same guarantee already checked inline for each sub-case of test 6;
# this is that same claim run as its own scenario, matching the design
# spec's own numbering, and additionally checks that NOTHING at all was
# written - no backup either, since validation fails before the "back up
# before writing" step is ever reached.)
# =====================================================================
S8="$WORK/s8"; mkdir -p "$S8"
CONFIG8="$S8/config.yaml"
make_base_config "$CONFIG8" "$S8/stream_key"
BEFORE8="$S8/before.yaml"
cp -- "$CONFIG8" "$BEFORE8"
ANSWERS8="$S8/answers.txt"
make_bad_answers "$ANSWERS8" "$S8/archive" "location.longitude" "500"

run_setup "$CONFIG8" "$ANSWERS8" >/dev/null 2>&1
rc8=$?
assert_true "test 8: an invalid answer aborts with a non-zero exit" bash -c "[ '$rc8' -ne 0 ]"
assert_eq "" "$(diff "$BEFORE8" "$CONFIG8" || true)" "test 8: config.yaml is byte-identical after an abandoned run"
mapfile -t backups8 < <(find "$S8" -maxdepth 1 -name 'config.yaml.bak-*' 2>/dev/null | sort)
assert_eq "0" "${#backups8[@]}" "test 8: no backup file was created either - validation fails before any writing begins"

# =====================================================================
# test 9: a missing config is created from config.example.yaml rather
# than from an internal template that could drift from it.
#
# Deliberately gives NO answers at all. Unlike every other scenario here,
# this one uses config.example.yaml UNMODIFIED - make_base_config's
# redirects would defeat the whole point, since the subject under test is
# exactly what the script copies when no config exists.
#
# That means the shipped defaults decide the outcome, and two required
# questions cannot be answered from them: the stream key (Q4, when
# /etc/pigeoncam/stream_key does not already exist) and
# archive.segment_dir (Q6, which ships empty on purpose). So the run
# always stops at an unanswerable required question - but WHICH one it
# names depends on whether this host happens to have a stream key file,
# since Q4 comes first.
#
# So assert the behaviour, not the key: the run fails, and it fails by
# naming a required key rather than silently defaulting one. An earlier
# version of this test asserted a specific outcome that held on a build
# machine and not on the deployment host - which is precisely where an
# operator is told to run `make check`. Both traps are the same mistake:
# asserting a fact about the host while believing it to be a fact about
# the wizard.
# =====================================================================
S9="$WORK/s9"; mkdir -p "$S9"
CONFIG9="$S9/config.yaml"
assert_file_not_exists "$CONFIG9" "test 9 setup: the target config does not exist yet"
ANSWERS9="$S9/answers.txt"
: > "$ANSWERS9"   # empty - every question falls back to "keep current"

err9=$(PIGEONCAM_CONFIG="$CONFIG9" "$SETUP" --non-interactive --answers "$ANSWERS9" 2>&1 1>/dev/null)
rc9=$?
assert_true "test 9: the run fails - a config straight from the example has a required key with no value" \
    bash -c "[ '$rc9' -ne 0 ]"
assert_contains "$err9" "no value for required key" \
    "test 9: it fails by naming a required key it cannot answer, rather than silently defaulting one"
assert_file_exists "$CONFIG9" "test 9: the missing config WAS created before the run finished"
assert_eq "" "$(diff "$EXAMPLE" "$CONFIG9" || true)" \
    "test 9: the created config is byte-identical to config.example.yaml (copied, not built from an internal template, and never edited before the run failed)"
assert_eq "$EXAMPLE_COMMENTS" "$(comment_count "$CONFIG9")" "test 9: the created config carries config.example.yaml's full complement of comment lines"

# =====================================================================
# supplementary: --non-interactive with NO --answers file at all reduces
# to a no-op that still exercises the write path (design spec, Q&A for
# --non-interactive without --answers) - every question keeps its
# current value, config.yaml ends up byte-identical, and a backup is
# still written.
# =====================================================================
S10="$WORK/s10"; mkdir -p "$S10"
CONFIG10="$S10/config.yaml"
KEYFILE10="$S10/stream_key"
make_base_config "$CONFIG10" "$KEYFILE10"
printf 'already-set-key\n' > "$KEYFILE10"; chmod 600 "$KEYFILE10"
BEFORE10="$S10/before.yaml"
cp -- "$CONFIG10" "$BEFORE10"

out10=$("$SETUP" --config "$CONFIG10" --non-interactive 2>&1)
rc10=$?
assert_eq "0" "$rc10" "supplementary: --non-interactive with no --answers at all still succeeds"
assert_eq "" "$(diff "$BEFORE10" "$CONFIG10" || true)" \
    "supplementary: a pure keep-everything-current run leaves config.yaml byte-identical"
assert_contains "$out10" "(nothing changed)" "supplementary: the summary correctly reports nothing changed"
mapfile -t backups10 < <(find "$S10" -maxdepth 1 -name 'config.yaml.bak-*' | sort)
assert_eq "1" "${#backups10[@]}" "supplementary: the write path still ran (a backup exists) even though nothing changed"

# =====================================================================
# supplementary: a required key with no current value AND no answer is a
# named, non-interactive-mode error - not just for the stream key (test
# 9 above) but for an ordinary config.yaml key too, e.g. a hand-edited
# config missing its external_check.channel_live_url line entirely.
# =====================================================================
S11="$WORK/s11"; mkdir -p "$S11"
CONFIG11="$S11/config.yaml"
KEYFILE11="$S11/stream_key"
make_base_config "$CONFIG11" "$KEYFILE11"
printf 'existing-key\n' > "$KEYFILE11"; chmod 600 "$KEYFILE11"
sed -i '/^  channel_live_url:/d' "$CONFIG11"
BEFORE11="$S11/before.yaml"
cp -- "$CONFIG11" "$BEFORE11"
: > "$S11/answers.txt"

err11=$("$SETUP" --config "$CONFIG11" --non-interactive --answers "$S11/answers.txt" 2>&1 1>/dev/null)
rc11=$?
assert_true "supplementary: a required key missing from the config with no answer fails" bash -c "[ '$rc11' -ne 0 ]"
assert_contains "$err11" "external_check.channel_live_url" "supplementary: the error names the actual missing key"
assert_eq "" "$(diff "$BEFORE11" "$CONFIG11" || true)" "supplementary: nothing was written when a required key was unanswerable"

# =====================================================================
# supplementary: the design spec's "never offer a YUYV mode at 1080p
# without repeating the silent-5fps warning" - applied regardless of
# interactivity, so a non-interactive --answers run choosing that exact
# combination still prints it, and a run that doesn't choose it, doesn't.
# =====================================================================
S12="$WORK/s12"; mkdir -p "$S12"
CONFIG12="$S12/config.yaml"
make_base_config "$CONFIG12" "$S12/stream_key"
ANSWERS12="$S12/answers.txt"
write_good_answers "$ANSWERS12" "$S12/archive"
sed -i 's/^camera.input_format=.*/camera.input_format=yuyv/; s/^camera.resolution=.*/camera.resolution=1920x1080/' "$ANSWERS12"
out12=$(run_setup "$CONFIG12" "$ANSWERS12" 2>&1)
assert_contains "$out12" "5fps" "supplementary: choosing yuyv at 1920x1080 prints the silent-5fps warning"

assert_not_contains "$out1" "5fps" \
    "supplementary: test 1's run (mjpeg at 1280x720) never prints the yuyv/1080p warning"

# =====================================================================
# supplementary: full-path key disambiguation. config.example.yaml has
# `enabled:` at the SAME indentation under seven different blocks
# (archive, external_check, watchdog.usb_reset, watchdog.frame_freeze,
# external_check.frame_freeze, reencode, youtube_api) and `mode:` at the
# same indentation under both youtube.rotation and
# external_check.frame_border - indentation plus leaf key name alone
# would find the wrong line for some of these. youtube_api.enabled is the
# only one of those this script ever answers; flipping it to true and
# asserting EXACTLY ONE line in the whole file changed is a direct check
# that yaml_find_line's full dotted-path tracking, not just "enabled: two
# spaces in", is what found the line.
# =====================================================================
S13="$WORK/s13"; mkdir -p "$S13"
CONFIG13="$S13/config.yaml"
make_base_config "$CONFIG13" "$S13/stream_key"
BEFORE13="$S13/before.yaml"
cp -- "$CONFIG13" "$BEFORE13"
ANSWERS13="$S13/answers.txt"
write_good_answers "$ANSWERS13" "$S13/archive"
sed -i 's/^youtube_api.enabled=.*/youtube_api.enabled=yes/' "$ANSWERS13"

out13=$(run_setup "$CONFIG13" "$ANSWERS13" 2>&1)
diff13=$(diff "$BEFORE13" "$CONFIG13" || true)
changed13=$(grep -c '^<' <<<"$diff13")
assert_eq "9" "$changed13" \
    "supplementary: flipping youtube_api.enabled adds exactly one more changed line to test 1's other 8 (proves it hit the right 'enabled:' among seven same-named keys)"
assert_eq "true" "$(yq -r '.youtube_api.enabled' "$CONFIG13")" \
    "supplementary: youtube_api.enabled itself really did flip, per real yq"
assert_eq "true" "$(yq -r '.archive.enabled' "$CONFIG13")" \
    "supplementary: archive.enabled (same leaf name, same indentation) is untouched"
assert_eq "true" "$(yq -r '.external_check.enabled' "$CONFIG13")" \
    "supplementary: external_check.enabled (same leaf name, same indentation) is untouched"
assert_eq "true" "$(yq -r '.watchdog.usb_reset.enabled' "$CONFIG13")" \
    "supplementary: watchdog.usb_reset.enabled (same leaf name, deeper indentation) is untouched"
assert_eq "false" "$(yq -r '.watchdog.frame_freeze.enabled' "$CONFIG13")" \
    "supplementary: watchdog.frame_freeze.enabled (same leaf name, deeper indentation) is untouched"
assert_eq "false" "$(yq -r '.external_check.frame_freeze.enabled' "$CONFIG13")" \
    "supplementary: external_check.frame_freeze.enabled (same leaf name, deeper indentation) is untouched"
assert_eq "false" "$(yq -r '.reencode.enabled' "$CONFIG13")" \
    "supplementary: reencode.enabled (same leaf name, deeper indentation) is untouched"
assert_contains "$out13" "YouTube API access requested" \
    "supplementary: enabling youtube_api.enabled prints the sign-in next-steps (design spec Q9)"
assert_contains "$out13" "--authorize" "supplementary: the next-steps mention the --authorize command"

# =====================================================================
# unit-level: yaml_find_line's full-path disambiguation, isolated from
# config.example.yaml's own key ordering. Every leaf name the wizard
# actually answers (see the scenario above) happens to be the LAST
# occurrence of that name in the real file, so a scenario-level test
# through the whole wizard cannot by itself distinguish "found the
# correct line" from "found the last line with this leaf name" - a bug
# that would still silently corrupt an answer for any OTHER key sharing a
# name with an earlier sibling (config.example.yaml has several:
# `youtube.rotation.mode` before `external_check.frame_border.mode`, six
# `enabled:` blocks before `youtube_api.enabled` itself). This fixture is
# built so the wanted key is the FIRST of two identically-named,
# same-indentation siblings, which a leaf-name-only match gets wrong
# regardless of scan direction. Runs in a throwaway subprocess (matching
# tests/test_err_trap.sh's own pattern for exercising a sourced function
# directly) rather than sourcing pigeoncam-setup.sh into this test file's
# own shell, so its globals and ERR trap never leak into this suite.
# =====================================================================
UNIT_FIXTURE="$WORK/unit-fixture.yaml"
cat > "$UNIT_FIXTURE" <<'EOF'
a:
  mode: first
b:
  mode: second
EOF
UNIT_RUNNER="$WORK/unit-runner.sh"
cat > "$UNIT_RUNNER" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/bin/pigeoncam-setup.sh"
yaml_find_line "$UNIT_FIXTURE" "a.mode"
EOF
chmod +x "$UNIT_RUNNER"
unit_line=$("$UNIT_RUNNER" 2>/dev/null)
assert_eq "2" "$unit_line" \
    "unit: yaml_find_line finds a.mode (line 2, the FIRST of two same-named siblings) rather than b.mode (line 4, the last) - proves full dotted-path tracking, not leaf-name-only matching"

test_summary_and_exit

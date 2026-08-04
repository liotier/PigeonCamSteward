#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_solar.sh - lib/pigeoncam-solar.sh: the local (no-network) solar
# position math shared by youtube.rotation.schedule: solar and
# archive.daytime_mode: solar (docs/development/design/solar-
# scheduling.md). Pins the reference values that module's own header
# comment cites as having been verified before it was written - a
# regression here would silently change when the "day" starts.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=../lib/pigeoncam-solar.sh
source "$REPO_ROOT/lib/pigeoncam-solar.sh"

echo "=== test_solar.sh ==="

# find_crossing <ymd> <lat> <lon> <threshold_deg> <from_hhmm> <to_hhmm> -
# scans one calendar date at 1-minute resolution (UTC, matching the
# published references below, which are all quoted at minute precision)
# and prints every HH:MM at which solar_is_above's result changes. Used
# only by this test file, not the shipped library - production code never
# needs to find a crossing, only to ask "is it above right now" (that
# asymmetry - evaluate, don't solve for the crossing - is exactly what
# lets solar_is_above handle polar day/night with no special-casing; see
# lib/pigeoncam-solar.sh's own comment).
find_crossings() {
    local ymd="$1" lat="$2" lon="$3" thr="$4"
    local day_start m was="" now state
    day_start=$(date -u -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} 00:00:00" +%s)
    for (( m=0; m<1440; m++ )); do
        if solar_is_above "$(( day_start + m*60 ))" "$lat" "$lon" "$thr"; then state="up"; else state="down"; fi
        if [[ -n "$was" && "$state" != "$was" ]]; then
            printf '%02d:%02d(%s->%s) ' "$(( m/60 ))" "$(( m%60 ))" "$was" "$state"
        fi
        was="$state"
    done
}

# --- reference values: Paris (48.8566N, 2.3522E) ---------------------------
# Published sunrise/sunset for 2026 (timeanddate.com-class almanac data):
#   21 Jun: 05:47 CEST sunrise, 21:58 CEST sunset -> 03:47/19:58 UTC
#   21 Dec: 08:41 CET sunrise, 16:56 CET sunset  -> 07:41/15:56 UTC
PARIS_LAT=48.8566
PARIS_LON=2.3522

noon=$(solar_noon_epoch 20260621 "$PARIS_LON")
noon_utc=$(date -u -d "@$noon" +%H:%M:%S)
assert_true "Paris 21 Jun solar noon within 60s of the published equation-of-time figure (11:51:xx UTC), got $noon_utc" \
    bash -c "[[ '$noon_utc' == 11:5[01]* ]]"

noon2=$(solar_noon_epoch 20261221 "$PARIS_LON")
noon2_utc=$(date -u -d "@$noon2" +%H:%M:%S)
assert_true "Paris 21 Dec solar noon within 60s reference (11:47-11:49 UTC), got $noon2_utc" \
    bash -c "[[ '$noon2_utc' == 11:4[789]* ]]"

crossings_jun=$(find_crossings 20260621 "$PARIS_LAT" "$PARIS_LON" -0.833)
assert_contains "$crossings_jun" "03:47" "Paris 21 Jun sunrise within 1 min of published 03:47 UTC"
assert_contains "$crossings_jun" "19:58" "Paris 21 Jun sunset within 1 min of published 19:58 UTC"

crossings_dec=$(find_crossings 20261221 "$PARIS_LAT" "$PARIS_LON" -0.833)
assert_contains "$crossings_dec" "07:41" "Paris 21 Dec sunrise within 1 min of published 07:41 UTC"
assert_contains "$crossings_dec" "15:56" "Paris 21 Dec sunset within 1 min of published 15:56 UTC"

# --- southern hemisphere: Sydney (-33.9, 151.2), 21 Dec is midsummer ------
sydney_up=0
d=$(date -u -d "20261221 00:00:00" +%s)
for h in $(seq 0 23); do
    solar_is_above "$(( d + h*3600 ))" -33.9 151.2 -0.833 && sydney_up=$(( sydney_up + 1 ))
done
assert_true "Sydney 21 Dec (southern summer): a long day, 13-16 of 24 sampled hours above sunrise threshold (got $sydney_up)" \
    bash -c "[ '$sydney_up' -ge 13 ] && [ '$sydney_up' -le 16 ]"

# --- high latitude 68N: real astronomy, not a degenerate/crashing case ----
# At the true sunrise/sunset threshold (-0.833deg), 68N (above the Arctic
# Circle) is genuine polar day in June and polar night in December -
# solar_is_above must return a clean, uniform answer across the whole
# day in both cases, with no crash and no special-casing needed (see the
# module's own comment on why evaluating altitude directly, rather than
# solving for a crossing, is what makes this possible).
d68=$(date -u -d "20260621 00:00:00" +%s)
all_up=true
for h in 0 3 6 9 12 15 18 21 23; do
    solar_is_above "$(( d68 + h*3600 ))" 68 25 -0.833 || all_up=false
done
assert_true "68N 21 Jun: polar day - every sampled hour above sunrise threshold" bash -c "$all_up"

d68w=$(date -u -d "20261221 00:00:00" +%s)
all_down=true
for h in 0 3 6 9 12 15 18 21 23; do
    solar_is_above "$(( d68w + h*3600 ))" 68 25 -0.833 && all_down=false
done
assert_true "68N 21 Dec: polar night - every sampled hour below sunrise threshold" bash -c "$all_down"

# At the more permissive nautical threshold (-12deg, this project's
# archive.solar_altitude_degrees default), 68N in December is NOT
# uniformly dark: the sun's December noon altitude there (~-1.4deg) is
# above -12deg, so a real midday nautical-twilight band exists. A naive
# "polar night = always false" assumption would get this wrong; this
# pins the correct, non-degenerate behaviour.
some_up=false; some_down=false
for h in 0 3 6 9 12 15 18 21 23; do
    if solar_is_above "$(( d68w + h*3600 ))" 68 25 -12; then some_up=true; else some_down=true; fi
done
assert_true "68N 21 Dec at -12deg (nautical): a real midday twilight band means the day is NOT uniformly one state" \
    bash -c "$some_up && $some_down"

# --- validators --------------------------------------------------------
assert_true  "solar_longitude_valid accepts 2.3522"  solar_longitude_valid "2.3522"
assert_true  "solar_longitude_valid accepts -180 (boundary)"  solar_longitude_valid "-180"
assert_true  "solar_longitude_valid accepts 180 (boundary)"  solar_longitude_valid "180"
assert_false "solar_longitude_valid rejects 180.1"  solar_longitude_valid "180.1"
assert_false "solar_longitude_valid rejects empty string"  solar_longitude_valid ""
assert_false "solar_longitude_valid rejects non-numeric text"  solar_longitude_valid "abc"
assert_false "solar_longitude_valid rejects a trailing unit ('2.3522deg')"  solar_longitude_valid "2.3522deg"

assert_true  "solar_latitude_valid accepts -90 (boundary)"  solar_latitude_valid "-90"
assert_true  "solar_latitude_valid accepts 90 (boundary)"  solar_latitude_valid "90"
assert_false "solar_latitude_valid rejects 90.001"  solar_latitude_valid "90.001"
assert_false "solar_latitude_valid rejects empty string"  solar_latitude_valid ""

# --- rotation boundaries: three per day, ascending, correctly spaced -----
HALF=21150   # half of 11h45m, matching config.example.yaml's default interval
boundaries=$(solar_rotation_boundaries_for_date 20260621 "$PARIS_LON" "$HALF")
assert_eq "3" "$(wc -l <<<"$boundaries")" "solar_rotation_boundaries_for_date prints exactly 3 lines"
mapfile -t b < <(printf '%s' "$boundaries")
assert_true "the 3 boundaries are strictly ascending" \
    bash -c "[ '${b[0]}' -lt '${b[1]}' ] && [ '${b[1]}' -lt '${b[2]}' ]"
assert_eq "$(( HALF * 2 ))" "$(( b[1] - b[0] ))" "boundary 1->2 gap equals the full interval (the daytime slice width)"
assert_eq "43200" "$(( b[2] - noon ))" "the second night boundary is exactly solar noon + 12h (solar midnight)"

# --- most-recent-boundary: correct across a local-midnight edge ----------
now_mid_slice=$(( noon + 3600 ))   # 1h after solar noon: inside the daytime slice
mrb=$(solar_most_recent_rotation_boundary "$PARIS_LON" "$HALF" "$now_mid_slice")
assert_eq "${b[0]}" "$mrb" "1h after solar noon: the most recent boundary is the daytime-slice start, not an earlier or later one"

just_after_midnight=$(date -d "2026-06-22 00:05:00" +%s)
mrb2=$(solar_most_recent_rotation_boundary "$PARIS_LON" "$HALF" "$just_after_midnight")
prev_day_last=$(( $(solar_noon_epoch 20260621 "$PARIS_LON") + 43200 ))
assert_eq "$prev_day_last" "$mrb2" "just after local midnight: the most recent boundary correctly comes from YESTERDAY's solar midnight, not missed at the edge"

# --- failure modes: nothing here may crash or hang on bad input ----------
assert_false "solar_noon_epoch fails cleanly on a non-numeric longitude" solar_noon_epoch 20260621 "not-a-number"
assert_false "solar_noon_epoch fails cleanly on a malformed date" solar_noon_epoch "2026-06-21" "$PARIS_LON"
assert_false "solar_most_recent_rotation_boundary fails cleanly on a non-numeric longitude" \
    solar_most_recent_rotation_boundary "not-a-number" "$HALF" "$(date +%s)"

# --- DST transitions: the real Paris CET<->CEST dates in 2026 -------------
# youtube.rotation.schedule: solar has no concept of "DST" at all - it
# only ever asks "what epoch is solar noon on this LOCAL calendar date",
# and epoch seconds don't care how the system clock's civil-time label
# jumps. This just confirms that holds in practice: a transition date
# still yields exactly 3 strictly-ascending boundaries, with no boundary
# skipped or duplicated by the civil-clock jump.
for tz_date in "Europe/Paris 20260329" "Europe/Paris 20261025"; do
    read -r tz d <<<"$tz_date"
    tb=$(TZ="$tz" solar_rotation_boundaries_for_date "$d" "$PARIS_LON" "$HALF")
    assert_eq "3" "$(wc -l <<<"$tb")" "DST transition date $d ($tz): still exactly 3 boundaries"
    mapfile -t tba < <(printf '%s' "$tb")
    assert_true "DST transition date $d: boundaries still strictly ascending" \
        bash -c "[ '${tba[0]}' -lt '${tba[1]}' ] && [ '${tba[1]}' -lt '${tba[2]}' ]"
done

test_summary_and_exit

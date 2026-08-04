# shellcheck shell=bash
# SPDX-License-Identifier: Unlicense
#
# pigeoncam-solar.sh - local (no-network) solar position calculations,
# shared by youtube.rotation.schedule: solar and archive.daytime_mode:
# solar (see docs/development/design/solar-scheduling.md). NOAA General
# Solar Position Calculations - verified numerically against published
# Paris (48.8566N, 2.3522E) sunrise/sunset (05:47/21:58 CEST on 21 Jun,
# 08:41/16:56 CET on 21 Dec) before this file was written, including the
# high-latitude (permanent day/night) and date-line-straddling edge cases -
# see that design doc for the verification transcript. Reproduce that
# check before trusting any change here.
#
# Not meant to be executed directly; source it, don't run it. Sourced by
# lib/pigeoncam-common.sh, so every script that sources common.sh gets
# this too.
#
# awk, not Python or bc: awk is already a dependency (daily_archive_gb in
# bin/pigeoncam-doctor.sh and others), Python only exists inside the
# optional youtube_api venv, and bc is not installed by default on minimal
# Debian. The installed awk here is mawk (verified: `awk -W version` ->
# mawk 1.3.4), which rejects gawk's `-e` and lacks gawk-only builtins
# (asort, strftime, systime, switch, length(array)) - none of those are
# used below. All arithmetic on values that came from `date`'s zero-padded
# output (day-of-year, hour, minute) happens inside awk, deliberately, not
# bash `$(( ))`: awk's numeric-string conversion reads "008" as decimal 8,
# while bash arithmetic reads a leading-zero literal as (invalid) octal -
# verified directly - the exact trap parse_duration_seconds and
# daily_archive_gb both already had to work around twice in this project.

if [[ -n "${PIGEONCAM_SOLAR_SH_LOADED:-}" ]]; then
    return 0
fi
PIGEONCAM_SOLAR_SH_LOADED=1

# The six NOAA coefficients, as one shared awk fragment every function
# below concatenates onto its own BEGIN block (bash string concatenation,
# not multiple -f files) - one copy, so they can't independently drift the
# way the timer/config duplication in pigeoncam-doctor.sh's
# check_timer_intervals once did (see that check's own comment).
_PIGEONCAM_SOLAR_AWK_FUNCS='
function rad(d){return d*3.14159265358979/180}
function gam(doy,hr){return 2*3.14159265358979/365*(doy-1+(hr-12)/24)}
function eqtime(g){return 229.18*(0.000075+0.001868*cos(g)-0.032077*sin(g)-0.014615*cos(2*g)-0.040849*sin(2*g))}
function decl(g){return 0.006918-0.399912*cos(g)+0.070257*sin(g)-0.006758*cos(2*g)+0.000907*sin(2*g)-0.002697*cos(3*g)+0.00148*sin(3*g)}
function noonmin(doy,lon,  g){g=gam(doy,12); return 720-4*lon-eqtime(g)}
function sinalt(doy,lon,lat,utcmin,  g,d,tst,ha){
    g=gam(doy,utcmin/60); d=decl(g)
    tst=utcmin+eqtime(g)+4*lon
    ha=rad(tst/4-180)
    return sin(rad(lat))*sin(d)+cos(rad(lat))*cos(d)*cos(ha)
}
'

# _pigeoncam_solar_is_number <value> - true if it looks like a signed
# decimal number (optionally fractional). Shared by both range validators
# below, per docs/development/design/solar-scheduling.md's "one shared
# helper" - only the acceptable range differs between latitude/longitude.
_pigeoncam_solar_is_number() {
    [[ "$1" =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]]
}

# solar_longitude_valid <value> - true iff it's a real number in [-180,180].
solar_longitude_valid() {
    local v="$1"
    _pigeoncam_solar_is_number "$v" || return 1
    awk -v v="$v" 'BEGIN{exit !(v>=-180 && v<=180)}'
}

# solar_latitude_valid <value> - true iff it's a real number in [-90,90].
solar_latitude_valid() {
    local v="$1"
    _pigeoncam_solar_is_number "$v" || return 1
    awk -v v="$v" 'BEGIN{exit !(v>=-90 && v<=90)}'
}

# solar_noon_epoch <YYYYMMDD> <longitude> - epoch seconds of true solar
# noon on the LOCAL calendar date YYYYMMDD, in the system's own timezone
# (no separate location.timezone config key - the same convention
# current_hhmm()/hour_in_daytime() already use: the operator's system
# clock is assumed to be set for where the camera actually is). Prints
# nothing and returns 1 if YYYYMMDD or longitude don't parse.
#
# doy (day-of-year, used to compute the equation of time and solar
# declination) is taken from the UTC calendar day that local noon falls
# on, not necessarily YYYYMMDD's own date - for any real-world timezone
# (UTC-12..UTC+14) local noon's UTC day differs from the local calendar
# day by at most one, and the equation of time changes slowly enough
# across a day (well under a minute, generally under ~20s even near the
# equinoxes) that this is not a practical source of error. Verified
# against Paris (UTC+1/+2, so this case never even arises there).
solar_noon_epoch() {
    local ymd="$1" lon="$2" local_noon_epoch utc_ymd doy noon_min utc_midnight_epoch
    [[ "$ymd" =~ ^[0-9]{8}$ ]] || return 1
    _pigeoncam_solar_is_number "$lon" || return 1
    local_noon_epoch=$(date -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} 12:00:00" +%s 2>/dev/null) || return 1

    read -r utc_ymd doy < <(date -u -d "@$local_noon_epoch" '+%Y-%m-%d %j') || return 1
    [[ -n "$utc_ymd" && -n "$doy" ]] || return 1

    noon_min=$(awk -v doy="$doy" -v lon="$lon" "$_PIGEONCAM_SOLAR_AWK_FUNCS"'BEGIN{printf "%.6f", noonmin(doy,lon)}') || return 1
    [[ -n "$noon_min" ]] || return 1

    utc_midnight_epoch=$(date -u -d "$utc_ymd 00:00:00" +%s 2>/dev/null) || return 1
    awk -v base="$utc_midnight_epoch" -v m="$noon_min" 'BEGIN{printf "%d", base + m*60 + (m>=0 ? 0.5 : -0.5)}'
}

# solar_sin_altitude <epoch> <lat> <lon> - sine of the sun's altitude at
# the given instant, on stdout. Comparing sin(altitude) against
# sin(threshold) directly (never taking an arcsin/arccos of either side)
# is what lets solar_is_above below work uniformly at any latitude,
# including permanent day/night, with no special-casing - verified
# against 68N in both June (permanent day) and December (permanent night
# at the sunrise threshold, but NOT at the nautical threshhold - a real
# midday nautical-twilight band exists there in December, which is
# correct astronomy, not a bug).
solar_sin_altitude() {
    local epoch="$1" lat="$2" lon="$3" doy hh mm ss utcmin
    _pigeoncam_solar_is_number "$lat" || return 1
    _pigeoncam_solar_is_number "$lon" || return 1
    read -r doy hh mm ss < <(date -u -d "@$epoch" '+%j %H %M %S' 2>/dev/null) || return 1
    [[ -n "$doy" ]] || return 1
    utcmin=$(awk -v h="$hh" -v m="$mm" -v s="$ss" 'BEGIN{printf "%.6f", h*60+m+s/60}')
    awk -v doy="$doy" -v lon="$lon" -v lat="$lat" -v utcmin="$utcmin" \
        "$_PIGEONCAM_SOLAR_AWK_FUNCS"'BEGIN{printf "%.8f", sinalt(doy,lon,lat,utcmin)}'
}

# solar_is_above <epoch> <lat> <lon> <threshold_degrees> - exit 0 if the
# sun's altitude at <epoch> is at or above <threshold_degrees>, exit 1
# otherwise. Common thresholds: -0.833 (sunrise/sunset, refraction + solar
# disc), -6 (civil twilight), -12 (nautical twilight, this project's
# default for archive.solar_altitude_degrees).
solar_is_above() {
    local epoch="$1" lat="$2" lon="$3" threshold_deg="$4" sinalt sinthr
    _pigeoncam_solar_is_number "$threshold_deg" || return 1
    sinalt=$(solar_sin_altitude "$epoch" "$lat" "$lon") || return 1
    [[ -n "$sinalt" ]] || return 1
    sinthr=$(awk -v t="$threshold_deg" 'BEGIN{printf "%.8f", sin(t*3.14159265358979/180)}')
    awk -v a="$sinalt" -v t="$sinthr" 'BEGIN{exit !(a>=t)}'
}

# solar_rotation_boundaries_for_date <YYYYMMDD> <lon> <half_width_seconds>
# - the three rotation-schedule boundaries for the given LOCAL calendar
# date, one per line, ascending: solar_noon-half (daytime slice starts),
# solar_noon+half (first night slice starts), solar_noon+12h == solar
# midnight (second night slice starts). No slice exceeds
# 2*half_width_seconds by construction, and the night split lands on
# solar midnight for free - see
# docs/development/design/solar-scheduling.md. Returns 1 (nothing
# printed) if solar_noon_epoch fails for that date.
solar_rotation_boundaries_for_date() {
    local ymd="$1" lon="$2" half="$3" noon
    noon=$(solar_noon_epoch "$ymd" "$lon") || return 1
    printf '%d\n%d\n%d\n' "$(( noon - half ))" "$(( noon + half ))" "$(( noon + 43200 ))"
}

# solar_most_recent_rotation_boundary <lon> <half_width_seconds> <now_epoch>
# - the largest rotation boundary at or before <now_epoch>, on stdout.
# Scans yesterday/today/tomorrow's LOCAL calendar dates (three full days
# of boundaries) rather than just today, so a boundary just after local
# midnight - or "now" landing just before it - is never missed at the
# edges, and so a machine that was off for a day still finds the right
# answer. Returns 1 only if boundaries could not be computed for ANY of
# the three days (e.g. an unparseable longitude) - a single day's failure
# (there isn't one in practice; solar_noon_epoch has no failure mode once
# its inputs validate) would not by itself make this fail.
solar_most_recent_rotation_boundary() {
    local lon="$1" half="$2" now="$3"
    local today_ymd d ymd b best="" found=0

    today_ymd=$(date -d "@$now" '+%Y-%m-%d') || return 1
    for d in "-1 day" "0 day" "+1 day"; do
        ymd=$(date -d "$today_ymd $d" '+%Y%m%d') || continue
        while IFS= read -r b; do
            found=1
            if (( b <= now )) && { [[ -z "$best" ]] || (( b > best )); }; then
                best="$b"
            fi
        done < <(solar_rotation_boundaries_for_date "$ymd" "$lon" "$half" 2>/dev/null)
    done

    (( found )) || return 1
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

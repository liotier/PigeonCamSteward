# Design spec: solar-relative rotation schedule and archive daytime

Status: **specified, not implemented.**

Two independent, separately-shippable features that happen to share one
numeric module:

1. **Rotation schedule** — `interval` (today's behaviour, stays the
   default) or `solar`: one maximum-length broadcast centred on solar
   noon, plus two shorter night broadcasts.
2. **Archive daytime window** — `fixed` (today's behaviour, stays the
   default) or `solar`: the retention/frame-freeze "daytime" window
   derived from the sun's actual altitude instead of two hard-coded
   `HH:MM` values.

Both fall back to their non-solar behaviour, with a logged warning, when
location is missing or invalid. Neither may ever prevent a rotation.

---

## Motivation, and one hard constraint

The goal is one good daytime archive per day, with the night broken into
two accessory pieces nobody will review closely.

**A single archive cannot cover the whole of daytime in summer.** YouTube
archives roughly 12 continuous hours; day length at mid latitudes is:

| lat | sunrise→sunset, June | December | nautical dawn→dusk, June |
|---|---|---|---|
| 43° | 15h22 | 9h00 | 18h05 |
| 46° | 15h45 | 8h38 | 18h47 |
| 48.85° | 16h11 | 8h15 | 19h38 |
| 51° | 16h33 | 7h55 | 20h29 |

So the feature is **"solar-noon-centred, maximum length"**, not "covers
daytime". It degenerates gracefully: in December an 11h45m window centred
on solar noon contains all the daylight with ~1h45m of margin at each
end; in June it is the best 11h45m available and clips roughly two hours
of dawn and two of dusk. Clipping symmetrically around noon is
deliberate — observed nest activity is spread through the day, so losing
equal amounts of early morning and late evening beats sacrificing either
one wholesale.

This must be stated plainly in the user documentation. An operator who
reads "solar daytime mode" and expects June dawn-to-dusk in one video
will otherwise think it is broken.

### Why the archive window is *not* just the rotation window

Reusing the rotation daytime slice as the archive daytime window is
tempting and wrong. The rotation slice is a fixed 11h45m year-round; real
daylight at 48.85°N in December is 8h15. Reusing it would classify ~3h30
of genuine darkness as "daytime", which:

- feeds near-dark frames to the frame-freeze check — the exact
  false-positive source `config.example.yaml` already warns about, and
- retains `daytime_keep_minutes` of black footage per dark hour, on a
  deployment that is storage-constrained enough to run
  `daytime_keep_minutes: 5`.

The two windows answer different questions ("when do we cut the
broadcast" vs "when is there light worth keeping"), so they stay separate
settings. They share the *module*, not the *answer*.

What is **not** true is that the archive side is significantly harder.
An earlier sketch claimed it needed `arccos` and special handling for
latitudes where dawn never happens. Evaluating altitude per hour instead
of solving for crossing times removes both (see below). The archive side
is roughly ten lines more than the rotation side, not a separate project.

---

## Shared module: `lib/pigeoncam-solar.sh`

A new file, sourced from `lib/pigeoncam-common.sh` so every script gets
it. Separate file rather than more lines in `common.sh` (already 567)
because it is self-contained numeric code with no other project
dependency, and it is the only part with real algorithmic risk — it earns
its own `tests/test_solar.sh`.

### Implementation constraints

- **`awk`, not Python or `bc`.** `awk` is already used in five places in
  `bin/`+`lib/`; Python only exists inside the `youtube_api` venv and
  must not become a core-rotation dependency. `bc` is not installed by
  default on minimal Debian.
- **The installed awk is `mawk 1.3.4`** (verified on the dev box). It has
  `sin`, `cos`, `atan2`, `exp`, `log` — everything needed. It does
  **not** support gawk's `-e`; pass the program as a single argument or
  via `-f`. Do not use gawk-only syntax (`asort`, `strftime`, `systime`,
  `switch`, `length(array)`, `RS` as a regex).
- **Epoch seconds are the only interchange type.** Compute in epoch,
  format only for display. Never compare wall-clock strings across a
  date, and never do arithmetic on local `HH:MM`. This makes DST
  transitions a non-event; `date -d`/`date -u -d @…` already handles the
  zone conversion.
- Guard every `x=$(…)` per working agreement 4.

### The algorithm (NOAA General Solar Position Calculations)

Verified against published values before this document was written —
Paris (48.8566N, 2.3522E) computed sunrise/sunset 03:47/19:58 UTC on
21 June (= 05:47/21:58 CEST, published 05:47/21:58) and 07:41/15:56 UTC
on 21 December (= 08:41/16:56 CET, published 08:41/16:56). Reproduce this
check before trusting any reimplementation.

Given day-of-year `doy` (1-based) and hour-of-day `hr` in UTC:

```
γ      = 2π/365 × (doy − 1 + (hr − 12)/24)

eqtime = 229.18 × ( 0.000075
                  + 0.001868·cos γ  − 0.032077·sin γ
                  − 0.014615·cos 2γ − 0.040849·sin 2γ )        [minutes]

decl   =   0.006918 − 0.399912·cos γ  + 0.070257·sin γ
         − 0.006758·cos 2γ + 0.000907·sin 2γ
         − 0.002697·cos 3γ + 0.00148·sin 3γ                    [radians]
```

Both quantities fall out of the same `γ` in one pass — which is why the
two features genuinely do share a module rather than merely a theme.

**Solar noon** (minutes UTC after midnight) needs only `eqtime` and
longitude — no latitude at all:

```
noon_min = 720 − 4×longitude − eqtime(γ at hr=12)
```

**Sine of solar altitude** at UTC minute-of-day `m` needs latitude too:

```
tst      = m + eqtime(γ) + 4×longitude          [true solar time, minutes]
H        = radians(tst/4 − 180)                 [hour angle]
sin(alt) = sin(lat)·sin(decl) + cos(lat)·cos(decl)·cos(H)
```

Compare `sin(alt)` directly against `sin(threshold)` — never take an
`arcsin`/`arccos`. Thresholds: `−0.833°` sunrise/sunset (refraction +
solar disc), `−6°` civil, `−12°` nautical.

Evaluating altitude rather than solving for crossings is what makes the
polar and wrap cases disappear. Verified: at 68°N on 21 June the sun
never crosses −12° at all (a crossing-based implementation gets an empty
list and must then disambiguate "always light" from "always dark"); in
Sydney on 21 December the crossings within a UTC day come out as
sunset-then-sunrise, because the local day straddles the UTC boundary.
Neither case needs any special handling when the only question asked is
"is `sin(alt)` above the threshold at this instant".

### Functions to expose

```
solar_noon_epoch <YYYYMMDD> <longitude>      -> epoch seconds
solar_sin_altitude <epoch> <lat> <longitude> -> float on stdout
solar_is_above <epoch> <lat> <longitude> <threshold_degrees>  -> exit 0/1
```

`<YYYYMMDD>` is a **local** date; resolve it to the UTC instant of local
noon via `date -d "<Y>-<M>-<D> 12:00:00" +%s` and derive `doy`/`hr` from
that with `date -u -d @<epoch>`. Do not compute day-of-year by hand.

---

## Feature 1: rotation schedule

### Config

```yaml
location:
  latitude: 48.8566      # only used by archive solar mode
  longitude: 2.3522      # used by rotation solar mode

youtube:
  rotation:
    schedule: interval   # interval (default) | solar
    interval: "11h45m"   # in solar mode this is the slice width / ceiling
```

`schedule:` is a new key. It must **not** be folded into the existing
`youtube.rotation.mode`, which already means `restart|api` — the two are
orthogonal (a solar schedule works with either mechanism).

### Boundaries

With `half = interval / 2` and `N = solar_noon_epoch(date, longitude)`,
each day contributes exactly three rotation boundaries:

| boundary | slice it opens | width (interval = 11h45m) |
|---|---|---|
| `N − half` | daytime | `interval` = 11h45m |
| `N + half` | first night | `12h − half` = 6h07m30s |
| `N + 12h` (solar midnight) | second night | `12h − half` = 6h07m30s |

The night split lands on solar midnight for free, and no slice exceeds
`interval`, so the ~12h ceiling holds by construction. Night slices are
positive for any `interval < 24h`; a value above ~11h50m defeats the
purpose and should be flagged by the doctor, not by this arithmetic.

### `check_rotation_due` in solar mode

Keep the function's existing contract exactly — stateless, marker-driven,
returns 0 when a rotation should happen. Only the predicate changes:

```
boundaries = for d in (yesterday, today, tomorrow):
                 N = solar_noon_epoch(d, longitude)
                 emit N − half, N + half, N + 12h
             sorted

most_recent = max{ b in boundaries : b <= now }

due  iff  marker_epoch < most_recent
```

Three days of boundaries is deliberate: it must be robust to a machine
that was off for a day and to solar noon drifting either side of local
midnight at extreme longitudes within a zone.

**Keep the interval check as a backstop**, OR-ed in:

```
due  ||  (now − marker_epoch) >= interval_seconds
```

The daytime slice is exactly `interval` wide, so this never fires
spuriously — but it guarantees that a bug anywhere in the solar path
still cannot strand a broadcast past the ceiling. That is the entire
reason this project exists; do not drop it for elegance.

`--force` continues to bypass the whole check, unchanged.

---

## Feature 2: archive daytime window

### Config

```yaml
archive:
  daytime_mode: fixed              # fixed (default) | solar
  daytime_start: "04:00"           # used when fixed
  daytime_end: "20:30"             # used when fixed
  solar_altitude_degrees: -12      # used when solar; -12 nautical,
                                   # -6 civil, -0.833 sunrise/sunset
```

### The gate

Today `hour_in_daytime <HH:MM> <start> <end>` is called from three
places, two of which pass "now" and one of which passes a **historical**
hour:

| caller | argument |
|---|---|
| `bin/pigeoncam-archive-trim.sh:72` | `hour_label` from a `YYYYMMDD_HH` segment prefix |
| `bin/pigeoncam-status-check.sh:104` | `current_hhmm()` |
| `bin/pigeoncam-watchdog.sh:93` | `current_hhmm()` |

That distinction is load-bearing. `archive-trim` sweeps *every* closed
hour still on disk, including backlog from previous days after downtime,
so a solar decision must be made **for that hour's own date**, not for
today. Using today's sun for a segment recorded three days ago is a real
bug, and in December vs June it is a several-hour error.

Introduce, in `common.sh`:

```
hour_is_daytime <YYYYMMDD> <HH>   -> exit 0/1
```

which dispatches on `archive.daytime_mode`:

- **fixed** — delegate to the existing `hour_in_daytime "$HH:00" …`,
  behaviour bit-identical to today.
- **solar** — resolve local `YYYYMMDD HH:30` to an epoch (the hour's
  midpoint, matching the existing whole-hour granularity), then
  `solar_is_above <epoch> <lat> <lon> <threshold>`.

Update the three callers: `archive-trim` passes the date it already has
in the prefix; `status-check` and `watchdog` pass today's date and hour.
Keep `hour_in_daytime` and `current_hhmm` exported — they are the fixed
path and are already covered by tests.

Retention semantics downstream (`daytime_keep_minutes`,
`nighttime_discard`) are untouched.

---

## Fallback behaviour (required)

Neither feature may fail closed. For each, at the point of use:

| condition | behaviour |
|---|---|
| `longitude` absent, empty, non-numeric, or outside [−180, 180] | rotation solar → fall back to interval schedule |
| `latitude` absent, empty, non-numeric, or outside [−90, 90] | archive solar → fall back to `daytime_start`/`daytime_end` |
| any solar computation returns a non-finite/unparseable result | same fallback as above |

Every fallback emits exactly one `log_warn` per run naming the offending
key, the value seen, and which mode is being used instead — e.g.
`location.longitude is not set; youtube.rotation.schedule is 'solar' but
falling back to the fixed 11h45m interval schedule this run. Set
location.longitude in /etc/pigeoncam/config.yaml.` Per-run, not per-hour:
`archive-trim` iterating twenty backlog hours must not emit twenty
identical warnings.

Validation lives in one shared helper so both features accept exactly the
same forms. Accept a leading `+`/`-` and a decimal point; reject
everything else. Remember `10#` on any integer arithmetic over
user-supplied numerals — this project has shipped the octal-leading-zero
bug twice already.

---

## Doctor checks

- `location.latitude`/`longitude` present and in range **whenever** a
  solar mode is selected → `FAIL` if not. Runtime keeps working via the
  fallback, but the operator asked for a mode that is not running, and
  that is a misconfiguration, not a preference. Message names the key and
  a plausible value.
- Both present but *reversed*-looking (|latitude| ≤ 90 always holds, so
  no reliable test) — skip; do not invent a heuristic.
- `youtube.rotation.interval` > `11h50m` → `WARN` in any schedule mode,
  naming the ~12h ceiling. Cheap, and independently useful.
- **Informational**: when solar rotation is active, print today's three
  boundary times in local time. This is the single most useful line the
  doctor can print for this feature — it turns an abstract config into
  "so it rotates at 07:58, 19:43, and 01:51".
- `recognized_config_keys()` extracts `cfg('.a.b')` call sites from
  source automatically, so new keys need no doctor edit — but
  `tests/test_config_schema.sh` asserts the reverse direction, so every
  new key **must** be added to `config.example.yaml` or that test fails.

---

## Tests

New `tests/test_solar.sh`:

- **Reference values.** Pin the verified figures above as fixtures —
  Paris 48.8566N/2.3522E, 21 Jun and 21 Dec, sunrise/sunset within
  ±2 min of 05:47/21:58 CEST and 08:41/16:56 CET; solar noon within
  ±60 s. Add at least one southern-hemisphere and one high-latitude
  location. Do not generate expectations from the implementation.
- **68°N, 21 June**: every hour is daytime at the −12° threshold, no
  crash, no empty-result special case.
- **68°N, 21 December**: no hour is daytime, same.
- **Sydney, 21 December**: local day straddling the UTC boundary is
  classified correctly hour by hour.
- **DST**: with `TZ=Europe/Paris`, the March and October transition dates
  each yield exactly three monotonically increasing rotation boundaries,
  and no hour is classified twice or skipped.

Extensions to existing suites:

- `test_rotate.sh` — solar schedule: due immediately after a boundary,
  not due just before one; the interval backstop still fires if the solar
  path is stubbed to return nonsense; `--force` still bypasses both.
- `test_archive_trim.sh` — a backlog hour carrying a **previous date's**
  prefix is judged by that date's sun, not today's. This is the
  regression test for the bug called out above; write it first and watch
  it fail against a naive implementation.
- `test_doctor.sh` — solar mode without location `FAIL`s and names the
  key; the boundary-times line appears when configured.
- `test_config_schema.sh` — new keys present in `config.example.yaml`.
- Fallback tests for every row of the table above, asserting both that
  the warning appears **and** that the run still does its job.

Per working agreement 2: each of these must be seen to fail before the
implementation exists.

---

## Files touched

| File | Change |
|---|---|
| `lib/pigeoncam-solar.sh` | **new** — the awk module and its shell wrappers |
| `lib/pigeoncam-common.sh` | source the above; add `hour_is_daytime`; add the location-validation helper |
| `bin/pigeoncam-rotate.sh` | `check_rotation_due` gains the solar branch + backstop |
| `bin/pigeoncam-archive-trim.sh` | pass the segment's own date into the gate |
| `bin/pigeoncam-status-check.sh` | frame-freeze gate → `hour_is_daytime` with today's date |
| `bin/pigeoncam-watchdog.sh` | same |
| `bin/pigeoncam-doctor.sh` | the checks above |
| `config.example.yaml` | `location:` block, `youtube.rotation.schedule`, `archive.daytime_mode`, `archive.solar_altitude_degrees` |
| `tests/test_solar.sh` | **new** |
| `tests/test_{rotate,archive_trim,doctor,config_schema}.sh` | extensions above |
| `README.md`, `docs/TROUBLESHOOTING.md` | user-facing description, including the summer-clipping caveat |

`systemd/pigeoncam-rotate.timer` is **unchanged**. Its 5-minute check
cadence is already the right substrate — an irregular schedule needs a
frequent poll and a stateless predicate, which is exactly what the
2026-08-04 fix left in place.

`bin/pigeoncam-status-check.sh`'s post-rotation grace period is also
unchanged: it reads `seconds_since_marker last_rotation_at`, not the
schedule, so an irregular rotation schedule is invisible to it. Verified
by reading the code, not assumed — FR7c's wording ("explicitly aware of
the rotation timer's schedule") suggests otherwise and is satisfied
through the marker.

---

## SPEC.md conformance

Additive; nothing here needs SPEC.md to change, and SPEC.md is frozen
regardless.

- **FR14** specifies "a systemd timer triggers `nestcam-rotate.sh` on a
  configurable interval (default `11h45m`)". `schedule: interval` remains
  the default, so the specified behaviour is what ships out of the box.
  FR14's stated purpose — "periodically break the connection for long
  enough that YouTube's archive isn't silently lost past its
  continuous-recording ceiling" — is satisfied by the solar schedule too,
  since no slice exceeds `interval`.
- **FR11** specifies "a configurable daytime window
  (`daytime_start`/`daytime_end`, default `04:00`–`20:30`)".
  `daytime_mode: fixed` remains the default and those keys keep working
  exactly as specified.

---

## Out of scope

- Any external almanac/API call. Everything here is computed locally; the
  project's "no cloud dependency for the default tier" rule (SPEC.md
  §"No cloud dependency") applies to rotation scheduling too.
- Per-slice titles/descriptions for the night broadcasts. Interesting
  with the YouTube API rotation mechanism, unrelated to scheduling.
- Twilight-aware *streaming* (stopping capture overnight). Out of scope
  and probably unwanted — the night broadcasts are explicitly wanted,
  just not curated.
- Any change to `daytime_keep_minutes` / `nighttime_discard` semantics.

## Suggested order

Rotation first, alone, and run it for several real days before starting
the archive side. The rotation change is the one with a visible failure
mode and a hard safety backstop; the archive change is reversible at any
time by flipping one key back to `fixed`.

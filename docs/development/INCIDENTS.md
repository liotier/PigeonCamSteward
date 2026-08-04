# Incidents

Post-mortems of bugs this project shipped, and of reasoning mistakes made
while diagnosing them. Kept because in every case the *class* mattered more
than the instance: the same shape came back more than once.

This is maintainer material. Nothing here describes something a current
user needs to act on — user-facing symptoms live in
[docs/TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

---

## The watchdog died silently, twice, from the same one-line shape

**Signature:** `pigeoncam-watchdog.service: Main process exited,
code=exited, status=1/FAILURE` repeating, with **no**
`pigeoncam-watchdog[…]:` line at all between "Starting" and the failure —
not even the routine "nothing to check" ones.

### Cause 1: SIGPIPE under `pipefail`

`progress_last_frame()` piped `tac | grep -m1 | cut`. `grep -m1` exits the
instant it matches, which — since `tac` reverses the file — happens within
the first few lines of output. Once the progress file grew past a trivial
size (a minute or two of real streaming; `-progress` writes continuously
and the file is never truncated within a run), `tac` was still writing when
`grep` closed the pipe, and `tac` died of SIGPIPE. Under `pipefail` the
whole pipeline reported failure *even though the correct value had already
been printed*, and because the caller used a bare
`cur_frame=$(progress_last_frame …)` rather than an `if`, `set -e` killed
the watchdog right there, before it logged anything.

In production the watchdog was therefore running successfully **well under
5% of the time** once a stream had been up more than a couple of minutes.
`Restart=always` covered for it well enough that nobody noticed until the
logs were read directly.

Fixed by reading the last few lines (`tail -n 20`) instead of reversing the
whole file — immune to the race, and faster.

### Cause 2: the same line again, different mechanism

The `tail` fix removed the race but not the fragility. If the progress file
exists but has no `frame=` line *yet*, `grep` finds nothing, exits 1,
`pipefail` propagates, and the same bare assignment under `set -e` killed
the watchdog just as silently.

That state is not an error: `pigeoncam-stream.sh` truncates the progress
file at every start, so it is the normal condition for the first moments of
**every restart**. The watchdog was blind for roughly the first half-minute
after each restart — exactly when a just-restarted stream is least stable —
and during a restart loop, blind essentially permanently.

Fixed in two places: `progress_last_frame()` now cannot return non-zero
(empty output is its documented answer for "no frame yet"), *and* the call
site appends `|| cur_frame=""` so no third upstream cause can repeat it.

### The class

**A bare `x=$(some_function)` under `set -euo pipefail` is a latent silent
`exit`.** Two more instances were caught before shipping (a `sha256sum`
masking a failed upstream; a `tail -c N | ffmpeg` frame grab that lost
frames to SIGPIPE in a size-dependent, therefore intermittent, way).

Write `x=$(…) || x=""`, or an explicit `if`, whenever the command can
legitimately produce nothing. The `ERR` trap in `lib/pigeoncam-common.sh`
now guarantees that any *unguarded* failure at least announces itself
before `set -e` exits.

---

## Diagnosing with a contaminated control

The `watchdog.frame_freeze` snapshot output causes periodic bursts of
`Non-monotonic DTS` / `Queue input is backward in time` in the stream log.

That was the original conclusion. It was then **retracted as wrong**, and
then reinstated — the retraction was the error. The bad step: comparing
against a "control" window in which the snapshot feature had already been
enabled part-way through, and reading an empty `grep` result over the
genuinely-clean window as "no data available" rather than what it actually
was, "zero occurrences".

What settled it was an exact-second timing correlation that holds across
three separate logs:

| event | time |
|---|---|
| ffmpeg start | 02:41:45 |
| snapshot output's first emission | 02:42:16 |
| first DTS burst | 02:42:16 |
| subsequent bursts | every 60s, matching every snapshot write |

plus a clean before/after: zero such warnings before the feature was
enabled, 1808 after.

**A contaminated control is worse than no control**, because it manufactures
confidence in the wrong direction.

### Mechanism, and what is still unverified

Not CPU cost — downscaling the snapshot from 1920x1080 to 480x270 changed
the bursts not at all. It is the periodic emission perturbing the shared
pipeline. Audio is the casualty rather than video because of an asymmetry
in our own argv: the v4l2 input gets `-thread_queue_size` (512) while the
pulse input gets none, leaving it at ffmpeg's default of 8 packets — too
shallow to absorb a stall. Late audio packets still carry their
capture-time timestamps, which is exactly what those two messages report.

Raising the pulse input's thread queue is the leading candidate fix and is
**unverified in the field**. The feature ships disabled; the durable fix is
to rebuild it on the segment ring specified in
[design/frame-freeze-from-segments.md](design/frame-freeze-from-segments.md),
which removes the extra output entirely.

---

## `main "$@" || exit $?` silently disables `set -e` everywhere

Found by adversarial review, before reaching production.

The shared `ERR` trap reports any unguarded non-zero command as "this is a
bug, not a normal fault". Two scripts exit non-zero as a deliberate
*report* rather than a fault — `pigeoncam-doctor.sh` ("some checks
FAILed") and `pigeoncam-ctl.sh status` ("a unit is down") — so both
announced a bug on a completely normal run. `ctl.sh status` against a
stopped stream is the single most routine thing an operator does while
troubleshooting, making it the worst possible moment to accuse the tool of
being broken.

The obvious fix — `main "$@" || exit $?` — is a far worse bug than the one
it fixes. Putting `main` in a condition context disables `set -e` for
`main` **and everything it calls, recursively**, and suppresses the trap
with it. Measured directly: a `set -euo pipefail` script written that way
ran straight past a failing command inside a nested function, printed the
line after it, and exited **0**.

On the watchdog or status-check that would silently undo both `set -e` and
the trap in one line, producing exactly the "reports healthy while blind"
behaviour this project exists to prevent.

**The correct fix:** have `main()` call `exit N` explicitly. A plain `exit`
does not trip the trap, and real failures deeper inside still do — both
verified directly. `tests/test_err_trap.sh` now fails the build if the
banned dispatch shape appears anywhere in `bin/`.

The general lesson: when a safety net produces a false positive, the fix
must not work by removing the net.

---

## Leading zeros are octal (again)

`parse_duration_seconds()` did `total=$(( total + num ))` on a substring
captured from a duration string. A perfectly reasonable `08h30m` or `09h`
made bash read `08`/`09` as an invalid octal literal, abort the function
with a raw `value too great for base` error, and fail the parse.

This is the **second** time this exact trap appeared here — `daily_archive_gb()`
already documents it for leading-zero `HH:MM` times, and already fixes it
the same way. Any arithmetic on a numeric substring that came from
user-editable text needs `10#`.

Failure direction was safe (an unparseable interval rotates anyway rather
than never rotating) but it leaked raw bash noise into the log and would
have disabled the boot-age check for anyone writing a leading zero.

---

## A capability quietly removed by a safety check

The boot-age gate added to `pigeoncam-rotate.sh` correctly stops a reboot
from stacking an extra rotation. It also, unintentionally, made **every**
operator-initiated rotation inside the interval a silent no-op.

Two ways that bites:

1. Triggering a rotation on demand to watch it work — the exact thing done
   to validate rotation changes — silently does nothing.
2. **Retrying a rotation that failed partway.** The marker is written
   *before* the sequence starts (deliberately, so the grace period covers
   the whole window), so a failed attempt has already reset the clock. The
   retry is refused for the full interval.

Fixed with an explicit `--force`, and by making the skip message name it.

The general lesson: a check that decides "no action needed" must say how to
override it, and adding one is a good moment to ask what the operator could
previously do that they now can't.

---

## A migration template with two invented config keys

Asked to port the operator's real production `config.yaml` from `tier2:`
to `youtube_api:`, without the real file in hand, a *template* was produced
instead — reconstructed from context, with the values only the operator
had marked `CHANGE ME`. Two of the values that weren't marked were wrong in
a way no amount of careful filling-in could have caught:

- `audio.thread_queue_size` — invented. No script reads it; only
  `camera.thread_queue_size` (a different key, for the video input) does
  anything. The name was lifted from this file's own DTS-burst write-up,
  which names a missing `-thread_queue_size` on the audio input as the
  *leading unverified hypothesis* for that bug — conflating "this is a
  plausible fix" with "this is implemented" produced a config key that
  looks like it configures the fix and does nothing.
- `watchdog.usb_reset.escalation_cooldown_seconds` — the real key,
  confirmed in `bin/pigeoncam-watchdog.sh`, is `cooldown_seconds`.

Both are silent no-ops: `cfg()` returns its built-in default when a key is
absent, so a config setting either key believes it has configured
something real. Caught only because the operator did the migration by hand
and asked for the result to be checked against their actual prior file —
not because anything in the toolkit itself would have noticed.

The same check also surfaced values that were never *wrong*, just
un-flagged: `archive.segment_dir`, `archive.daytime_start`, and
`external_check.frame_freeze.enabled` all carried real, deployment-specific
values in the operator's original config that the template silently
replaced with generic defaults, because only the obviously-secret-shaped
values (stream key, hub location, channel URL, stream id) had been marked
for attention. Anything else deployment-specific was invisible as
"something to check" the same way the two invented keys were.

Fixed two ways:

- `pigeoncam-doctor.sh` gained `check_unrecognized_config_keys()`: every
  leaf key actually read anywhere in `bin/`, `lib/`, `api/` is extracted
  from the source itself (not a hand-maintained list — the whole point,
  see `recognized_config_keys()`'s own comment on why item 3c's
  timer/interval duplication is the cautionary example not to repeat),
  diffed against every leaf key present in the config being checked. A key
  that parses as valid YAML and isn't read by anything gets a WARN naming
  it exactly. Verified to correctly flag both invented keys, and to
  produce zero false positives against `config.example.yaml`.
- The habit this leaves behind: a from-scratch template standing in for a
  file that could not be read is exactly the situation with no defense
  against this - reconstructing a config (or anything else) from context
  rather than the real source needs to say so plainly, not just mark the
  obviously-secret fields and imply the rest is safe.

---

## A `--force` rotation the timer never found out about

**Signature:** a broadcast ran 14 hours instead of rotating at the
configured ~11h45m interval, with no error anywhere in the log.

### Reconstruction

The field log for the missed rotation showed no `pigeoncam-rotate`
failure, no gap in the watchdog's 30-second heartbeat (ruling out a clock
jump — checked by diffing every `Finished pigeoncam-watchdog.service`
timestamp across the whole window, 2409 of them, rather than trusting a
single before/after subtraction), and no obvious cause at all in the
units that were actually logging. What broke the case was tracking the
YouTube broadcast ID recorded in each `status-check`'s "confirmed live
(id=…)" line across the whole log: it changed once, around 10:31–10:40,
with nothing in `pigeoncam-rotate`'s own journal at that time. A rotation
had happened — just not one systemd's own units had any record of,
because it had been run directly (`pigeoncam-rotate.sh --force` from an
interactive shell), which never "activates" `pigeoncam-rotate.service`
and therefore never resets `pigeoncam-rotate.timer`'s
`OnUnitActiveSec` countdown.

### Why that stranded the broadcast for so long

`OnUnitActiveSec=` counts from when the *timer's target unit* last
activated — on every firing, whether or not the script's own logic found
anything to do. The design at the time set `OnUnitActiveSec` to match
`youtube.rotation.interval` (11h45m) on the theory that the timer's own
schedule could be the single source of truth for when to check — correct
for the boot case (`OnBootSec=5min` already existed, precisely because a
reboot can leave an old broadcast running with no other trigger — see the
"capability quietly removed" entry above for the check it works
alongside), but wrong in steady state, where an out-of-band rotation can
happen at any point in the interval.

The out-of-band `--force` reset the *marker* (`last_rotation_at`) but not
the *timer*. The timer's next scheduled firing — still counting from
whenever `pigeoncam-rotate.service` had last activated, hours before the
`--force` — landed correctly, checked the marker, correctly saw "not due
yet," and skipped. That firing, however, still counted as an activation,
so the timer's *following* elapse was scheduled a full 11h45m out from
*it* — stranding the broadcast for roughly 23 hours before anything
looked again, about double the ~12h ceiling this project exists to stay
under.

### Fix

Extend the same principle already used for the boot case to steady
state: the timer's own schedule is never the authority on whether a
rotation is due, only `pigeoncam-rotate.sh`'s own age check against the
durable marker is. `OnUnitActiveSec` in `systemd/pigeoncam-rotate.timer`
changed from `11h45m` to `5min`, matching `OnBootSec`, so both cases now
share one mechanism: a frequent, cheap check that is almost always a
fast no-op, with the marker deciding everything. This requires **no**
change to `pigeoncam-rotate.sh` itself — `check_rotation_due()` was
already stateless and marker-driven; it was only ever called too rarely.

`pigeoncam-doctor.sh`'s timer/config sync check (`check_timer_intervals`)
previously asserted `pigeoncam-rotate.timer`'s `OnUnitActiveSec` matched
`youtube.rotation.interval` — that assertion is now backwards, so it was
removed from that check's comparison list rather than "fixed," with a
comment explaining why a match would now be the wrong thing to want.

The general lesson: a schedule and a state marker are two different
things, and a fix that makes the schedule track the marker in one
direction (boot) can leave it silently *not* tracking it in another
(everything else). Once a marker is the real authority, checking often
and cheaply is more robust than trying to keep every path that can move
the marker in sync with the timer that reads it.

---

## `$ok && result PASS` as a function's last line trips the ERR trap

Found by this feature's own test suite, before shipping - `pigeoncam-
doctor.sh`'s new `check_archive_daytime_mode()` produced
`this is a bug, not a normal fault` on every legitimate `FAIL` it
reported, exactly the false-positive class the
`main "$@" || exit $?` incident above already exists to prevent.

The function set `ok=false` in each `FAIL` branch and ended with
`$ok && result PASS "..." "..."` - a pattern copied from
`check_youtube_api()`, where it has always been safe, but for a reason
that pattern-matching alone didn't surface: `check_youtube_api()` has an
unconditional `mode=...`/`if [[ "$mode" != "api" ]]; then result WARN
...; fi` block *after* that line, so `$ok && result PASS` is never
actually the function's last executed statement there, and the function's
real return status always comes from that later `if`. In the new
function, `$ok && result PASS ...` genuinely was the last statement -
`false && anything` evaluates to 1, and since a bare `false` is one of
`&&`'s two operands, it does not trip the ERR trap or `set -e`
*directly* - but the whole `$ok && result PASS ...` expression's own
exit status (1, propagated from `false`, with `result PASS` never even
running) became the function's return value. `check_archive_daytime_mode`
is then called unguarded from `main()` (`if`/`&&`/list membership does
not apply to a function *call site* that is itself a bare statement), so
that returned 1 reached the trap exactly like any other unguarded
failure would.

**Fixed** by replacing it with `if $ok; then result PASS ...; fi`, which
returns 0 whether or not the branch runs (verified directly: `if false;
then echo x; fi; echo $?` prints `0`). `tests/test_doctor.sh` gained a
regression test in the same style as the existing `yuyv_trap` ERR-trap
check, and was confirmed to fail against the original `$ok &&` form
before the fix, per the fail-then-pass discipline this project applies to
every fix.

The general lesson, sharper than "avoid `main "$@" || ...`" alone: **any
function called as a bare, unguarded statement must not let its own last
line's exit status leak out as an accidental return value** - a
conditional expression that is merely *safe as a statement*
(`COND && CMD` never trips `set -e`/the trap on its own) is not
automatically *safe as a function's tail*, because the function's return
value is a second, independent place the same exit status can resurface.
Copying a pattern from elsewhere in the file does not verify it - the
original context that made it safe (a later unconditional statement) is
exactly the part that doesn't copy along with the snippet.

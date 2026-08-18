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

---

## A YouTube-side display glitch, and two falsified theories

**Signature:** the operator noticed part of the archived footage on
YouTube itself rendering at the wrong aspect ratio - full frame for a
while, then a smaller, pillarboxed picture for the rest of that
broadcast (one case started outright square before correcting itself
over nine hours later). Not visible in the local archive, only in
YouTube's own copy.

### Theory 1: caused by a reconnect

The first two examples each had a real local incident (a USB dropout,
then later an RTMPS `Broken pipe`) within a few minutes of the
approximate moment the aspect ratio changed. Reasonable-looking, and
wrong: a third broadcast had a `Broken pipe` reconnect of its own and
stayed completely fine. A cause that isn't necessary to produce the
effect isn't the cause.

### Theory 2: still explainable as "every broadcast start is a reconnect too"

When the operator reported that one broadcast was wrong from its very
start - not mid-stream - that looked at first like it might still fit
the reconnect theory (a fresh broadcast is, mechanically, the biggest
reconnect there is). It doesn't survive the same test theory 1 failed:
asked for the operator's *exact* elapsed-time offsets rather than
eyeballed screenshots, and searching the real log at the precisely
computed wall-clock windows found **nothing** - no restart, no error, no
reconnect, not even a delayed one - at either transition moment. Whatever
changed, changed with the local system sitting completely idle.

### Where this landed

Neither theory survived contact with precise timestamps. The honest
conclusion: nothing in this project's own logs correlates with either
occurrence. Once a frame leaves ffmpeg over RTMPS, YouTube's own
transcoding/storage/serving pipeline is completely opaque from here -
there is no log to read that would explain this, because the event
doesn't happen on a machine this project has any visibility into.

**What shipped instead of a fix:** `record_broadcast_start()`
(`lib/pigeoncam-common.sh`), called from both rotation modes in
`bin/pigeoncam-rotate.sh`, appends one line per broadcast (id, real
go-live time, scheduled-vs-`--force`) to a durable
`/var/lib/pigeoncam/broadcast_log`. It doesn't detect the glitch - nothing
here can - but it turns "what time did this broadcast actually start"
from a multi-step log-archaeology exercise (exactly what both theories
above required, done by hand) into a single lookup, so the *next*
occurrence can be checked against precise timestamps immediately instead
of approximated after the fact from a screenshot's elapsed-time counter.

The general lesson: a correlation found by hand, from approximate
timestamps, is a hypothesis, not a finding - it survives only as long as
nobody checks it against the precise numbers. Getting the exact
timestamps here (rather than accepting "within a few minutes" as good
enough) was what actually falsified both theories. And a system's logs
can only ever rule things out on *its own* side of a boundary
(RTMPS, in this case) - a clean result there is real information ("not
caused by anything we did"), not a dead end.

---

## `systemd-run --on-calendar="08:45"` doesn't mean "once"

**Signature:** two consecutive mornings, the archived broadcast was
unexpectedly short. `broadcast_log` makes the shape exact: on
2026-08-07, `Xdcqhisf-i0` started 08:21:29 and was replaced 24 minutes
later, at 08:45:20; on 2026-08-08, `REBp_fzSFvA` - the specific broadcast
the operator flagged - started 07:51:34 and was replaced 54 minutes
later, at 08:45:20 again. Both replacements are logged as `force`, not
`scheduled`, and both land within a second of the same time of day.

### Finding it

Nothing owned by this project explained a daily 08:45 force rotation.
The search went through both root's and the operator's own crontab,
every `systemd --user` timer, running processes, `screen`/`tmux`
sessions, and a `pigeoncam`-filtered `journalctl` - all clean, because
none of them could have found what was actually responsible. Only an
*unfiltered* `journalctl` window, not scoped to any unit name, surfaced
it:

```
Aug 08 08:45:01 sikasso systemd[1]: Started run-p3525633-i3525933.service - [systemd-run] /opt/PigeonCamSteward/bin/pigeoncam-rotate.sh --force
```

Getting the search window right took two attempts. The first, centered
on `broadcast_log`'s own 08:45:20 entry, came up empty - that timestamp
is written by `record_broadcast_start` *after* the rotation finishes,
not when the command was invoked. A healthy automated rotation elsewhere
in the same log showed the real shape: about 5 seconds from invocation
to stream restart, then another ~15 seconds to the logged completion -
roughly 20 seconds end to end. Backing that out from 08:45:20 put the
actual invocation at the top of the minute, not :10 or :20 as the first
window had assumed. The corrected window, 08:44:55-08:45:08, is what
caught the `Started run-p...` line at 08:45:01.

### Root cause

Days earlier, the operator had asked, once, to "schedule rotation for
tomorrow morning at 8H45AM." The command given for it:

```bash
sudo systemd-run --collect --on-calendar="08:45" /opt/PigeonCamSteward/bin/pigeoncam-rotate.sh --force
```

`--on-calendar="08:45"` - a bare time of day, no date - is standard
systemd `OnCalendar=` syntax, and it does not mean "the next 08:45,
once." It means "08:45, every day, forever" (the same recurrence
`OnCalendar=daily` would give, just anchored to a different time of
day), and the first firing simply being the very next 08:45 is just what
starting that schedule looks like. `--collect` only garbage-collects
each firing's own transient service record afterward - it has no effect
on the timer itself, which keeps re-arming on the same schedule
indefinitely. The explanation given alongside the command at the time
("resolves to the next upcoming 08:45 - tomorrow, since today's has
already passed") was true, and said nothing about what happened after
that.

So every morning from then on got an uninvited extra `--force` rotation
at 08:45, landing in the middle of whatever broadcast the normal
schedule had already started, and cutting it short. `REBp_fzSFvA` and
`Xdcqhisf-i0` were not two unrelated short mornings - they were the same
one-line schedule, still firing days after being asked to run once, for
"tomorrow morning."

### The fix

Operationally: `systemctl list-timers --all`, look for the `run-*.timer`
entry (its own name is a random-looking id - `run-p3525633-i3525933`
here - with nothing in it to identify which command it runs), then
`systemctl stop` on it.

In the docs: `docs/TROUBLESHOOTING.md`'s own recipe for scheduling a
`--force` rotation used exactly the bare-time form above as its example.
Rewritten to lead with a full absolute date and time
(`--on-calendar="2026-08-10 03:00:00"`, which really is one-shot, since
a specific past moment can't recur), with an explicit warning about the
bare-time trap, and pointing at the unfiltered `run-*.timer` search
above instead of a name-based one that would never match.

### The class

A primitive whose default is "repeat forever" satisfies a "just this
once" request perfectly well on the first firing, and then keeps
going - correctly, by its own rules, generating no error and nothing
that looks broken - for as long as nobody remembers it's still armed.
The bug here was never in this project's own code; it shipped in a
copy-pasteable command, and in documentation that showed a
technically-true example without ever saying it needed to be taken back
out. Worth keeping alongside that: the diagnostic dead end wasn't a lack
of effort, it was that every avenue tried - crontab, user timers,
name-filtered journal search - was the wrong *kind* of search for a
mechanism with no persistent config file and no name of its own. A
transient unit's identity is generated at creation specifically because
it isn't meant to be looked up later, which is exactly what made it
invisible until the search stopped filtering by name at all.

---

## Pillarboxing, round three: one real correlation, two more clean misses

**Signature:** during a heatwave, the operator found the camera housing
extremely hot to the touch and reported the aspect-ratio glitch three
times in one day - twice on the broadcast then live (`hb2c5UjX9Js`), once
on the previous night's second broadcast (`wWysBYYTpOc`) - this time with
precise elapsed-time offsets for all three transitions, precise enough to
test against exact log windows rather than approximate ones.

### The heat theory, tested and mostly not supported

A real, measurable local symptom did show up in that day's log: every
stream-service instance logged periodic "N frames duplicated" warnings
(ffmpeg padding output when real capture frames arrive slower than the
target rate), at a strikingly *constant* rate across every daytime
instance - about 3m20s to the first 1000-frame milestone, every time,
whether the hour was mild morning or the hottest part of the afternoon.
The one outlier ran *faster*, not slower: a pre-dawn restart hit the same
milestone in 75 seconds, before sunrise, nowhere near the heat. Frame
duplication turned out to correlate with low light, not temperature - a
different, calmer explanation than the one the report started with, and
the numbers said so, not a guess.

Three genuine stream-service restarts happened that same day, each about
a minute after an identical root cause never seen in this project's logs
before: `ioctl(VIDIOC_DQBUF): No such device` / `Error during demuxing:
No such device` at 05:47:17, 08:53:40, and 16:50:21 - the capture device
disappearing out from under ffmpeg, at every time of day, not
preferentially in the heat either.

### The first real correlation this saga has ever found

The operator's precise elapsed-time offset for `wWysBYYTpOc`'s switch
(3:46:25 into that broadcast) computed to a window of 05:46:50-05:47:20.
The `No such device` error for that exact broadcast landed at 05:47:17 -
inside the window, to the second, not "within a few minutes" the way
every previous candidate in this saga has been. That's the first local
event this whole investigation has ever found that actually lines up
with a reported switch.

It didn't generalize. The same broadcast (`hb2c5UjX9Js`) had two more
reported switches that day, at precisely computed windows around 12:11
and 15:39 - both checked against the raw log, both widened by several
extra minutes just in case, and both came up completely empty, the
identical shape as every previously falsified theory in this file. That
same broadcast even had its own second `No such device` fault that day
(08:53:40) with no reported switch anywhere near it - though that's not
proof nothing happened then, only that nobody was watching closely
enough to notice if it did.

### Where this actually lands

Not one root cause - at least two independent mechanisms producing the
same visible symptom. A genuine local device fault can trigger it
(confirmed, once, precisely). Something with no local trace at all can
*also* trigger it (confirmed, twice, on the same day, on the same
broadcast). RTMPS stays a real opacity boundary for the second class;
the first class, at least, is now a real, actionable, first-ever finding
instead of a hypothesis.

**What shipped:** `external_check.frame_border`
(`lib/pigeoncam-common.sh`'s `frame_border_from_url`,
`bin/pigeoncam-status-check.sh`'s `sample_frame_border`/
`check_frame_border`/`handle_frame_border`) - ffmpeg's own `cropdetect`
filter run against the same frame `external_check.frame_freeze` already
fetches, watching for a black border on any edge. `mode: warn` only
notifies; `mode: rotate` additionally forces a rotation, the same remedy
this whole saga has used by hand every time - still not a confirmed fix,
since a fresh broadcast has started wrong from its first frame before,
just the best lever available. It doesn't resolve the RTMPS-side class -
nothing local can - but it closes the loop on the class that does have a
local signal, turning "check by hand when a viewer happens to notice"
into an automatic, sustained (`confirm_count`), immediate response.

---

## `frame_border`'s own false positive: twilight, not YouTube

**Signature:** deployed with `mode: rotate`, the feature built to catch
pillarboxing produced a symptom of its own instead: consistently short
broadcasts, with none of the visible wrong-aspect-ratio signs the earlier
entries in this file describe. Six days of real production log gave an
unusually clean pattern - all 11 `FRAME_BORDER_ROTATE` firings landed
either 05:00-06:10 or 18:26-22:21, never once during actual daylight.

### Ruling out a real recurrence

One firing alone at dawn wouldn't mean much - a broadcast starting at a
bad moment is exactly what earlier entries in this file describe. What
ruled that out: on three separate mornings, a broadcast that had just been
force-rotated *for* a confirmed border got hit with another confirmed
border of its own, 57-67 minutes later, on a completely fresh broadcast
that had only just gone live. A real YouTube-rendering fault has no reason
to recur on a brand-new broadcast, tied to the same clock window, three
mornings running. A condition that's still true when the new broadcast
starts does.

### The mechanism

`frame_border` inherits its daytime gate from `frame_freeze`
(`hour_is_daytime`, solar-altitude based) rather than defining its own -
deliberate, since it was built to piggyback entirely on `frame_freeze`'s
existing fetch. That gate is wide enough for what `frame_freeze` actually
needs: its hash comparison only requires the scene to visibly change
between samples, which it does even in dim twilight as the sky brightens
minute to minute. `frame_border`'s `cropdetect` check needs something
stricter - the frame has to actually be bright - and a merely-dim (not
literally black) dawn or dusk frame can cross the same near-black
threshold a real border would, with nothing actually wrong with the
picture. The border readings themselves fit: heavily bottom-weighted
(0.37-0.42), a shape that never appeared in any of the confirmed
pillarboxing cases from the earlier entries in this file.

### The fix

`external_check.frame_border.min_solar_altitude_degrees` (default 6, a
little past actual sunrise/sunset) - a second, stricter light gate
specific to this one check, evaluated at the current moment via the same
`solar_is_above` this project already uses for rotation scheduling and
archive trimming, not a fixed-minutes buffer around the existing gate.
Minutes were considered and rejected: how long twilight actually *lasts*
varies by season and latitude (materially so, at this project's
reference latitude, in summer), so a buffer tuned to look right one week
can be quietly wrong months later for the exact same real brightness -
exactly the seasonal drift solar-altitude scheduling already exists
elsewhere in this project to avoid. Falls back to no extra restriction if
`location.latitude`/`longitude` are missing, consistent with every other
solar fallback in this project - `frame_freeze`'s own gate already warns
about that condition, so this doesn't repeat the warning for the same
root cause.

The general lesson: a detector built to close one false-negative (missing
a real fault) can open a new false-positive of its own, and the two don't
announce themselves the same way - this one took a working production
deployment and a clean multi-day pattern to actually see, not code review.
Reusing another check's gate is reusing its *tolerances* too, not just its
plumbing; the two checks reading the same frame wanted different things
from the light in it.

---

## The aspect-ratio glitch, finally identified: a square transcode ladder

**Signature:** the pillarbox/vignette symptom from the entries above
returned, with `frame_border` deployed in `mode: rotate` and not firing.

### What it actually is

One command settled what three previous investigations could not -
`yt-dlp -F` against the live URL, listing what YouTube is actually
serving:

```
93 mp4 360x360    94 mp4 480x480    95 mp4 720x720    96 mp4 1080x1080
```

**Every rendition square.** Not player-side rendering, not an artifact of
which rendition got picked: YouTube's own transcode ladder was 1:1, and a
correct 16:9 ingest was being letterboxed into it. `cropdetect` on the
fetched 1080x1080 frame gave `crop=1080:608:0:236` - 21.85% black top and
bottom, over four times `min_border_fraction`.

So the fault was never invisible to `frame_border`. It is exactly what
that check was built to see.

### Why it hadn't fired

Sampling polls are separable from plain ones in the journal by cost
(~9s CPU versus ~4.4s, since only a sampling poll fetches and decodes),
which reconstructs the sample times exactly. For the affected broadcast:
`08:24 · 08:57 · 09:31 · 10:04 · 10:37 · 11:11`, all reading clean, then
`11:17` - the first sample after an `EXTERNAL_RESTART` - reading square.
One bordered sample by the end of the log, against a `confirm_count` of
3. Nothing had failed; the evidence simply wasn't in yet.

Two things made that latency much worse than intended:

**A duplicate YAML key.** The operator's `frame_border` block had
`confirm_count` twice - `2`, then `3` further down (both from a snippet
this project's own maintainer supplied). YAML takes the last, silently,
and `pigeoncam-doctor.sh`'s unrecognized-key scan cannot see it, because
by the time `yq` answers, the duplicate is already resolved away. A key
the operator explicitly set to one value was quietly running at another.

**A 30-minute sample interval.** `check_interval_seconds` governs
detection latency for `frame_freeze` and `frame_border` alike, and both
require `confirm_count` consecutive samples: 60+ minutes of broken
picture before anything could act. Lowered to 540s (9 minutes) as part of
this incident - the real cost of sampling more often is bandwidth (two
separate ffmpeg fetches per sample, ~8 MB), not API throttling.

### A wrong call, corrected

The entry immediately above concluded all 11 of `frame_border`'s field
firings were twilight false positives. That was over-generalized from a
real dawn/dusk cluster: the Aug 13 18:26 firing read
`0.0000:0.0000:0.2185:0.2185` - the exact square signature measured here -
in full afternoon daylight. It was a true positive, dismissed because it
sat in a list of false ones. The light gate remains the right fix for the
dawn/dusk cluster; the sweeping claim about the whole set was wrong, and
a genuine confirmed detection went unrecognized for days because of it.

### The trigger, and an interaction between two remedies

The square ladder appeared at an `EXTERNAL_RESTART` - the `frame_freeze`
remedy, which is a plain `systemctl restart` and therefore keeps the
*same* broadcast while giving YouTube a fresh ingest session to
re-derive the ladder from. A rotation creates a new broadcast, and with
it a new ladder; a restart cannot. So one health layer's remedy can
create the fault the next layer exists to catch - and only the second
layer's remedy clears it.

This partly rehabilitates Theory 1 from the "two falsified theories"
entry above. A reconnect is not *sufficient* (most reconnects are
completely fine, which is what falsified it as a sole cause), but it does
look *necessary*: it is the moment YouTube gets to re-derive the ladder,
and occasionally derives it wrong.

Making rotation the first freeze remedy was considered and deliberately
**not** done on n=1 evidence: rotation would fragment the archive on
every freeze, disrupt live viewers, perturb the solar schedule, and spend
API quota, to remove a latency the interval change had just cut roughly
sevenfold. The layers already compose - restart is the cheap first
remedy, and `frame_border` catches and rotates if it goes wrong. If
restart-to-square proves reliably reproducible rather than a one-off,
the middle path is restart on attempt 1 and rotation from attempt 2.

The general lesson, and it is the same one this file keeps recording from
a new angle: **a detector reporting nothing is not evidence of nothing.**
Three separate investigations concluded the fault was invisible from this
side, and it never was - the question "what is YouTube actually serving?"
simply hadn't been asked directly. One `yt-dlp -F` answered in seconds
what a lot of careful log correlation could not, because it interrogated
the boundary rather than reasoning about what lay past it.

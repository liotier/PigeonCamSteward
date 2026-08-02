# Design spec: architecture-review items 2, 3 and 5

Status: **implemented** (2a, 2b, 3a/3b/3c, 5 - all in this document).
Three independent changes from the 2026-08-02 architecture review. Each
was separately implementable and separately revertable; they were
collected in one document only because items 2 and 5 share a delivery
mechanism. Implemented in the order the user specified: 2a, then 5, then
2b, then 3 (highest risk, last).
One deviation from the design below: 3a's durable directory
(`PIGEONCAM_DURABLE_DIR`, default `/var/lib/pigeoncam`) is an
environment-variable override, not derived from `tier2.state_file` via
`cfg()` as originally sketched - test fixtures that append their own
`tier2:` block (YAML's last-top-level-key-wins) would have silently
clobbered a `tier2.state_file`-derived path, which would have meant
tests writing into the real `/var/lib/pigeoncam` unnoticed. The constant
still defaults to the exact same path tier2.state_file uses.

Ordering note: **all three are worth strictly less than review item 1**
(`notify_command` actually being set). Items 2 and 5 create new alert
*sources*; if `notify_command` is empty they produce log lines nobody
reads, which is the status quo. Item 1 is the operator's, is already in
progress, and is the prerequisite that gives items 2 and 5 their value.

---

# Item 2: make silent death impossible

## Problem

Three times, a reliability script has died mid-run and logged **nothing
at all**:

| Occurrence | Mechanism |
|---|---|
| `progress_last_frame`, `tac \| grep -m1` | SIGPIPE under `pipefail` |
| `progress_last_frame`, `grep` no-match | non-zero exit under `pipefail` |
| `frame_hash_from_url` (caught pre-production) | `sha256sum` masking a failed upstream |

A fourth was found while specifying the freeze-detection ring
(`tail -c … \| ffmpeg`, SIGPIPE again) and never shipped only because it
happened to be measured.

Every one shares a shape: `x=$(pipeline)` as a bare assignment under
`set -euo pipefail`. `set -e` then exits the script *at that line*,
before any logging. The watchdog in particular was blind for ~30 s after
every restart for an unknown period, and nobody could have known.

Individual instances are now fixed. **The class is not.** There are ~15
shell scripts under `set -euo pipefail` in this project; the next
occurrence is a matter of time, and its signature will again be
`Main process exited, code=exited, status=1/FAILURE` with an empty
journal.

## Design

Two independent layers. Either alone is a large improvement; together
they cover both "the script died" and "the script died and nobody was
told".

### 2a. `ERR` trap in the shared library

`lib/pigeoncam-common.sh` installs, at source time:

```
pigeoncam_on_err() {
    local rc=$? line=${BASH_LINENO[0]} cmd=$BASH_COMMAND
    log_error "unhandled failure at ${BASH_SOURCE[1]:-?}:${line} (exit ${rc}) running: ${cmd}"
    log_error "this is a bug - a script exited without logging why. See docs/TROUBLESHOOTING.md 'Historical: pigeoncam-watchdog.service failing with no log output at all'"
}
trap pigeoncam_on_err ERR
set -o errtrace   # required: without it the trap is not inherited by functions/subshells
```

Notes that matter for the implementer:

- `set -o errtrace` (`set -E`) is **not** optional. Without it an `ERR`
  trap does not fire inside shell functions - which is precisely where
  every one of the failures above occurred.
- The trap does not change control flow: `set -e` still exits. It only
  guarantees a diagnostic first. Deliberate: silently *continuing* past
  an unexpected failure is how a watchdog reports healthy while blind.
- `ERR` does not fire for failures in a condition context
  (`if cmd`, `cmd || fallback`, `!cmd`), so the project's many
  intentional `|| return 0` guards stay silent. That is the correct
  split: guarded failure is handled, unguarded failure is a bug.
- Scripts that source the lib get this for free with no per-script
  change - the whole point.

### 2b. `OnFailure=` on every oneshot unit

Each oneshot unit (`watchdog`, `status-check`, `rotate`, `archive-trim`,
`ytdlp-update`) gains:

```
OnFailure=pigeoncam-failure-notify@%n.service
```

and one new template unit `pigeoncam-failure-notify@.service` runs a
small script that calls the existing `notify_escalation` with a
`UNIT_FAILED` label and the failed unit's name, so the operator learns
about it through the same channel as every other escalation.

This is the belt to 2a's braces: it fires even for deaths a shell trap
cannot catch (OOM kill, SIGKILL, an interpreter that never got far
enough to source the library).

`pigeoncam-stream.service` is deliberately excluded: `Restart=always`
means it "fails" routinely and by design during normal recovery, and
alerting on that would be noise. Its coverage comes from the watchdog and
status-check layers.

## Test plan

- A script that sources the lib and runs an unguarded failing command
  exits non-zero **and** emits a line containing the failing command and
  source line.
- The existing `|| return 0` guards produce no such line (no
  false-positive noise) - assert against `progress_last_frame` with an
  empty progress file, the exact shape that used to die.
- `set -o errtrace` regression: the same failure *inside a function*
  still logs. This is the assertion that would have caught all three
  historical incidents.
- Fake-systemd coverage for `OnFailure=` wiring is not attempted (out of
  reach for this suite); unit-file syntax is checked by
  `systemd-analyze verify` if available, else skipped.

## Risk

Low, and asymmetric in the right direction: a trap that fails to fire
leaves today's behaviour; a trap that fires spuriously produces a log
line. Nothing changes control flow.

One real caveat: `set -E` changes trap inheritance globally for every
script sourcing the lib. If any existing code relies on a function's
failure being silently swallowed *and* is not written as a guarded
condition, it will start logging. That is information, not breakage, but
expect one round of noise triage on first deployment.

---

# Item 3: a reboot must not silently extend a broadcast past the ceiling

## Problem

Three facts combine into a latent recurrence of the original
stuck-stream failure:

1. `pigeoncam-rotate.timer` is `OnBootSec=11h45m` +
   `OnUnitActiveSec=11h45m`. After a reboot the schedule re-anchors to
   **boot**, not to broadcast age.
2. `last_rotation_at` lives in `/run/pigeoncam/` - **tmpfs**, erased by
   the reboot.
3. A restart resumes the *same* YouTube broadcast rather than starting a
   new one (field-confirmed by the operator on 2026-08-02).

Therefore: a reboot at hour 11 of a broadcast's life produces a next
rotation at broadcast-age ~23 h - roughly double YouTube's ~12 h
continuous-archive ceiling, and squarely the condition that produced the
stuck broadcast this project was built to prevent. Trigger required:
a power cut. No code fault, no operator error.

This has probably not fired yet only because the host reboots rarely.

## Design

Three parts, smallest first.

### 3a. Persist the rotation timestamp

`last_rotation_at` moves from `/run/pigeoncam/` to
`/var/lib/pigeoncam/` - the same durable location
`tier2.state_file` already uses, for the same reason.

Requires a new `marker_path`-adjacent helper (or a `durable_marker_path`)
rather than changing `marker_path` wholesale: `started_at` **must stay in
tmpfs**, because "when did the current ffmpeg process start" is
meaningless across a reboot and a stale value would suppress
`grace_period_after_restart_seconds` exactly when it is needed. Getting
this backwards would be worse than the bug being fixed.

Missing file (first run, fresh install) keeps the existing
`seconds_since_marker` semantics: a very large number, i.e. "rotation is
due", which fails safe.

### 3b. Rotate on boot if the broadcast is already old

`pigeoncam-rotate.sh` gains an early age check: if
`seconds_since_marker last_rotation_at` exceeds
`youtube.rotation.interval`, rotate now. With 3a in place this makes the
boot case self-correcting - the timer's `OnBootSec` fires at most
11h45m after boot, but the *first* such firing now sees the true age and
acts on it.

Residual gap, stated honestly: between boot and that first firing there
is still a window of up to `OnBootSec` during which an over-age
broadcast keeps running. Closing it fully means `OnBootSec` small (e.g. 5
min) so the age check runs shortly after every boot and becomes a no-op
when the age is genuinely low. **Recommended:** set `OnBootSec=5min` and
let the age check decide, rather than letting the timer's schedule be
the sole authority.

### 3c. Stop duplicating the interval in two places

`pigeoncam-rotate.timer` hard-codes `11h45m` with a comment instructing
the operator to keep it in sync with `youtube.rotation.interval` by hand.
The same duplication exists for `watchdog.check_interval_seconds` and
`external_check.poll_interval_seconds`. Nothing detects divergence.

Minimum viable fix (no new machinery): `pigeoncam-doctor.sh` grows a
check comparing each timer's `OnUnitActiveSec` against the corresponding
config value and warning on mismatch. This turns a silent incoherence
into a visible one, which is all that is needed - the values change
rarely.

Explicitly **not** proposed: generating unit files from config. That
adds a build step to a project whose stated problem is accumulated
complexity.

## Test plan

- `last_rotation_at` written to the durable path; `started_at` still
  written to tmpfs (assert both paths explicitly - the failure mode is
  swapping them).
- Age check triggers a rotation when the marker is backdated beyond the
  interval, and does not when it is recent (standard backdating
  discipline, as in `test_watchdog.sh`).
- Missing marker → rotation due, not skipped.
- Doctor warns on a deliberately mismatched timer/config pair, and is
  silent when they agree.

## Risk

Moderate, and the highest of the three items: this changes when
rotations happen, and rotation is historically the most failure-prone
operation in the system. The age check must not be able to fire twice in
quick succession (write `last_rotation_at` *before* the sequence begins -
`pigeoncam-rotate.sh` already does exactly this, for exactly this
reason). First deployment should be watched, and the first boot after it
watched specifically.

---

# Item 5: sustained INDETERMINATE must eventually alert

## Problem

`pigeoncam-status-check.sh` classifies every poll as confirmed-live,
confirmed-not-live, or indeterminate, and **never acts on
indeterminate** - deliberately, and correctly: it is why an ISP blip has
never caused a restart storm. This is one of the best decisions in the
design and this item must not weaken it.

But "never acts" currently also means "never escalates, ever". If yt-dlp
breaks against a YouTube frontend change, every poll goes indeterminate
**forever**, the external check is silently dead, and the only
notification is its absence. Two of the three log lines are:

```
INDETERMINATE: could not confirm live status (network/DNS/extractor issue?) - no action taken, will retry next cycle
INDETERMINATE: yt-dlp output was not valid JSON - no action taken, will retry next cycle
```

Both at `log_warn`, both invisible without someone reading the journal.

## Design

Add a counter, not an action. State gains
`consecutive_indeterminate`, incremented on every indeterminate poll and
**reset to zero on any determinate outcome** (live or not-live). When it
crosses `external_check.indeterminate_alert_after` (default: 20 polls ≈
1 hour at the default 180 s interval):

```
notify_escalation EXTERNAL_CHECK_BLIND "N consecutive indeterminate polls (~M minutes): the external YouTube check cannot see the stream either way and has been unable to for this entire period. The stream itself may be fine - this reports that one health layer is blind, not that the stream is down. Most likely causes: yt-dlp needs updating (see pigeoncam-ytdlp-update.timer), a persistent network fault, or a YouTube frontend change."
```

Then re-arm rather than repeat: alert again only after another full
threshold, so a multi-day outage produces hourly-ish notices rather than
one per poll.

**The check still takes no corrective action.** No restart, no
escalation ladder, no Tier 2 recovery. It only tells the operator that a
sensor has gone blind. That distinction is the entire design.

Wording matters more than usual here: the operator must not read this as
"the stream is down" and start intervening in a healthy system at 3am.
The message says so explicitly.

## Test plan

- Threshold-1 indeterminate polls → no notification; threshold → exactly
  one; further polls → none until the next full threshold.
- Any determinate outcome resets the counter (assert an
  indeterminate→live→indeterminate run does not accumulate).
- No restart or escalation is ever issued on any indeterminate path
  (assert the fake systemctl log stays empty) - this is the regression
  that protects the "indeterminate never acts" invariant.
- Default `0` disables the alert entirely.

## Risk

Very low. Adds one counter and one notification path; touches no
decision logic. The one way to get it wrong is resetting the counter in
the wrong place, which the third test pins.

---

## Suggested implementation order

1. **Item 2a** (`ERR` trap) - smallest, protects everything implemented
   afterwards, including items 3 and 5.
2. **Item 5** - trivial once `notify_command` is set, and immediately
   closes a known blind spot.
3. **Item 2b** (`OnFailure=`) - more unit-file surface, less urgent than
   2a.
4. **Item 3** - highest risk, touches rotation; do it last, on a day
   with attention available, and watch the first boot after.

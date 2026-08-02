# Design spec: local content-freeze detection from a segment ring

Status: **specified, not implemented**. Replaces the retired in-process
snapshot mechanism (`watchdog.frame_freeze`'s `snapshot_path` era) for
good. See docs/TROUBLESHOOTING.md "Non-monotonic DTS" for why that
mechanism is known-harmful and must not be resurrected.

Revision note: an earlier draft of this spec sourced its sample from the
**archive's** in-progress segment, which made detection depend on
`archive.enabled`. That coupling was rejected on review ("I really want
detection to perform independently of archival") and the rejection was
correct - see "Why the archive-reading draft was wrong" below. This
version uses a dedicated ring and is independent of archive settings.

## Problem statement

A camera/USB fault can leave the device technically responsive but
redelivering stale frames: ffmpeg's `frame=` counter advances, the
progress file stays fresh, and every local health layer reports healthy
while viewers see a frozen image. This blind spot is confirmed real
(three field incidents). The previous attempt to close it - a second
ffmpeg output inside the streaming process - is confirmed harmful (one
total outage, one viewer-visible audio disruption) and is disabled in
production. The YouTube-side check (`external_check.frame_freeze`)
covers this class only with a ~66-minute floor at production settings
(33-min sampling × 2 confirmations), which the operator has beaten by
hand every single time.

## Core principle

**Detection consumes; it never perturbs.** The detector must not add a
filter, must not emit in bursts, must not be able to fail the stream,
and must not require any cleanup machinery. It writes to RAM, is
self-limiting, and is read by a separate short-lived process.

## Mechanism: a self-limiting ring on tmpfs

A third `tee` branch writes a tiny wrapping segment ring to
`/run/pigeoncam/` (tmpfs, already this project's runtime directory):

```
[f=segment:segment_time=20:segment_wrap=2:segment_format=mpegts:onfail=ignore]/run/pigeoncam/detect/ring%d.ts
```

`segment_wrap=2` means exactly two files ever exist, cycling - no
trimming, no growth, no cleanup timer, nothing to leak. Verified: 45 s
of stream produced exactly `ring0.ts` + `ring1.ts` where an unwrapped
segmenter would have produced five files, and the archive branch running
alongside was unaffected.

Steady-state RAM at 6 Mbps CBR: 2 × 20 s ≈ 30 MB of tmpfs. Configurable.

Why this is not the mechanism that broke production:

| | retired snapshot output | this ring |
|---|---|---|
| Filter | `-vf fps=1/60` - buffers 59 s, then emits in a burst | **none** |
| Emission | one spike per minute (the DTS cause) | continuous, every frame |
| Muxer | `image2` + `-update 1` - overwrite prompt, needed `-y` (the crash-loop cause) | `segment`, the same muxer family the archive branch has run for weeks |
| Failure containment | none | `onfail=ignore`, same protection the archive branch already relies on |

Both identified failure mechanisms are absent by construction, not by
hope. This is materially lower risk - but see "Honest risk accounting".

## Reading a frame: `-sseof`, never `tail | ffmpeg`

```
frame_hash_from_ring <segment_path> <seek_seconds> <timeout_seconds>
    h=$(set -o pipefail; timeout <t> nice -n 19 ffmpeg -v error \
          -sseof -<seek_seconds> -i <segment_path> \
          -frames:v 1 -f rawvideo -pix_fmt yuv420p - 2>/dev/null \
        | sha256sum | cut -d' ' -f1) || return 0
    printf '%s' "$h"
```

`-sseof -N` seeks to N seconds before end-of-file. **Do not implement
this as `tail -c N file | ffmpeg -i pipe:`.** That form was tried and is
broken in a way that is invisible in small-file testing:
`ffmpeg -frames:v 1` exits as soon as it has its frame, closing the
pipe while `tail` is still writing, so `tail` dies of SIGPIPE and
`pipefail` rejects a perfectly good decoded frame. Measured directly:

```
2.4 MB file -> PIPESTATUS(tail,ffmpeg) = 0,0     works
8.0 MB file -> PIPESTATUS(tail,ffmpeg) = 141,0   frame decoded, then discarded
```

Size-dependent, therefore intermittent, therefore exactly the kind of
bug that reaches production. This is the **third** appearance of the
SIGPIPE-under-`pipefail` trap in this project (see `progress_last_frame`
and its second cause in TROUBLESHOOTING.md); `-sseof` removes the pipe
entirely and with it the whole class. It also removes the `tail_bytes`
tuning knob an earlier draft needed.

The `|| return 0` around the command substitution - never a bare
assignment - is load-bearing for the same reason it is everywhere else
in this codebase.

### Verified behaviour on a live, growing file

Against a segment being actively written by a real encoder, sampling
every 8 s:

```
sample 1  size=34.6 MB  hash=3aecc092...
sample 2  size=46.4 MB  hash=537b9ea5...   <- content moving: hash CHANGED
sample 3  size=46.4 MB  hash=537b9ea5...   <- content static: hash IDENTICAL
```

Both required properties demonstrated on real data: changing content
never produces a false freeze, static content is detected. `-sseof` also
decoded cleanly from a 35 MB archive segment, so file size is not a
constraint.

## Placement: inside the existing watchdog, no new unit

`check_local_frame_freeze()` in `bin/pigeoncam-watchdog.sh` is rewritten
to sample the ring. Rationale: the escalation ladder it needs - plain
restart, then USB reset on recurrence - already lives there, and a
camera-side freeze is precisely the fault class FR7b's USB reset exists
for. Adding a seventh unit would violate the architecture review's own
anti-complexity conclusion. The watchdog remains a 30-second oneshot;
the check only decodes when its own slower interval has elapsed.

Sampling target: newest `ring*.ts` by mtime. If it yields an empty hash
(just wrapped, no keyframe yet), fall back once to the second-newest -
with `segment_wrap=2` a complete previous segment is always present.
Still empty after both: "not counted either way".

## Gating

| Gate | Rule | Rationale |
|---|---|---|
| Config | `watchdog.frame_freeze.enabled`, default `false` | Opt-in |
| Daytime | `hour_in_daytime` vs `archive.daytime_start/end` | Near-dark frames hash identical legitimately. **Note:** these two keys are read even when `archive.enabled` is false - they are the project's daytime window, not an archive-only setting. Unfortunate naming, not a coupling |
| Startup grace | `seconds_since_marker started_at` ≥ `check_interval_seconds` | A just-restarted stream has no baseline |
| Freshness | newest ring file mtime within `2 × watchdog.check_interval_seconds` | A stale ring means the stream is down - that is the existing stall path's job; sampling it would double-count one fault as two |
| Interval | `now − last_sample_at ≥ check_interval_seconds` | Decode cost control |

**No gate on `archive.enabled` or `archive.segment_format`.** That is the
entire point of this revision.

## Decision logic (unchanged shape, proven in the YouTube-side twin)

- Empty hash → "not counted either way", logged at info. Never evidence.
- Hash == previous → `consecutive_frozen++`; else reset counter, store
  new baseline.
- `consecutive_frozen ≥ confirm_count` → `stalled=true,
  content_frozen=true` → the **existing** ladder: distinct
  `confirmed FROZEN` log line, `STALL_RESTART`, USB-reset escalation on
  recurrence, freeze-tracker reset after any action. State fields
  (`last_sample_hash`, `last_sample_at`, `consecutive_frozen_samples`)
  in `watchdog.state`; tmpfs loss on reboot is correct (fresh baseline).

## Config block (replaces the known-harmful one wholesale)

```yaml
watchdog:
  frame_freeze:
    enabled: false
    ring_dir: /run/pigeoncam/detect   # tmpfs; self-limiting, never needs cleanup
    ring_segment_seconds: 20          # 2 files of this length ever exist
    check_interval_seconds: 300       # MTTD ≈ interval × (confirm_count+1) ≈ 15 min
    confirm_count: 2
    seek_seconds: 3                   # -sseof offset; must exceed one GOP (2s default)
    decode_timeout_seconds: 20
```

`snapshot_path` / `snapshot_interval_seconds` cease to exist; old keys in
a deployed config are harmlessly ignored. RAM cost is
`2 × ring_segment_seconds × encode.bitrate_kbps`; `pigeoncam-doctor.sh`
should report it alongside its existing free-space check (B2), since
tmpfs exhaustion would be a novel failure mode.

## Why the archive-reading draft was wrong

The first draft read the archive's in-progress segment: zero pipeline
change, but detection silently inert whenever `archive.enabled` was
false, and gated on `segment_format: mpegts`. It was defended on the
grounds that any second output repeats this week's mistake.

That reasoning conflated *a* second output with *the specific* second
output that broke - as the table above shows, the snapshot's two failure
mechanisms (burst emission, image2 overwrite semantics) are both absent
from a continuous, unfiltered segment branch. A detector whose coverage
silently depends on an unrelated storage feature is its own reliability
defect: it is exactly the "you believe you're covered and you're not"
shape as the silently-dying watchdog.

Answering the review question directly - *is it only that a temporary
directory has to be specified?* No. A directory alone is inert; the
stream has to actually be **written** there, and only the streaming
ffmpeg can do that. Hence the tee branch. But the cost of that branch is
~30 MB of RAM and one muxer, not a new failure mode.

## Honest risk accounting

This design re-enters the streaming argv, which the previous one also
did before breaking production twice. The differences are identifiable
and mechanical rather than reassuring generalities (no filter, no burst,
proven muxer, `onfail=ignore`, tmpfs so no disk contention). But
"identifiably lower risk" is not "no risk", and the retired snapshot was
also introduced with a comment claiming zero impact on non-adopters.

Therefore: default off, first field enablement follows the watched-deploy
rule (daylight, operator at the console), and the first thing to check
after enabling is `journalctl -u pigeoncam-stream | grep -c "Non-monotonic
DTS"` - if that count climbs from zero, revert immediately and the design
is wrong.

## Removal scope (half the feature)

1. `bin/pigeoncam-stream.sh`: delete the snapshot output block and its
   config reads. `-y` **stays** (independently correct for an unattended
   service); its comment is retitled as history.
2. `config.example.yaml`: KNOWN-HARMFUL block deleted, replaced by the
   above.
3. Tests: snapshot-argv assertions replaced by a negative assertion
   (`-f image2` never in argv, under any setting); fixtures/schema keys
   swapped.
4. `docs/TROUBLESHOOTING.md`: the "Non-monotonic DTS" entry gains a
   closing paragraph - root cause removed entirely, entry kept as
   history.

## Test plan (argv-text tests are insufficient; field-proven this week)

- **Real-ffmpeg tests** (skip-if-no-ffmpeg, like
  `test_offline_reencode.sh`): a real three-branch tee; assert the ring
  self-limits to exactly two files while a third branch keeps writing;
  `-sseof` decode of the newest ring file yields exactly one frame;
  changing content → differing hashes; static content → identical
  hashes; a freshly-wrapped file yields empty and falls back to the
  second-newest.
- **A regression test pinning the `-sseof` decision**: assert the
  implementation contains no `tail -c ... | ffmpeg` form, with the
  PIPESTATUS evidence cited in the test's own comment, so nobody
  "simplifies" it back into the SIGPIPE trap.
- **Watchdog integration** via the existing fake-ffmpeg `FRAME_MODE`:
  confirm-count ladder, daytime gate, freshness gate, post-restart
  baseline reset, decode-failure neutrality, and inertness when
  disabled.
- Every new test verified failing pre-fix before landing.
- Explicitly *not* claimed testable in a sandbox: scheduler interaction
  with a real encode under sustained load. The design minimises that
  surface; the DTS counter check above is the field acceptance test.

## Explicitly out of scope

Notify wiring (review items 1/5), sustained-INDETERMINATE handling, the
reboot/rotation-age flaw (item 3), any SPEC.md edit (this fits within
FR7/FR7b's existing mandate).

## Open design calls (operator may veto before implementation)

1. **Ring conditional on `frame_freeze.enabled` (proposed) vs always
   present.** Always-present would make the streaming argv identical for
   every deployment, so detection could never be blamed for a pipeline
   change - arguably the purest form of "detection never perturbs" - at
   the cost of ~30 MB tmpfs for users who never enable it. Proposed:
   conditional, since imposing cost on non-users to protect a default-off
   feature is the wrong trade.
2. **Living inside the watchdog** rather than a separate timer unit:
   fewer moving parts, and process isolation is already total either way.
3. **mpegts-only** for the ring: conservative and matches the archive's
   proven format; no reason to make this configurable.

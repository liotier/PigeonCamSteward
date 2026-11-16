# Design spec: local content-freeze detection from a segment ring

Status: **specified, not implemented** - revision 3 (2026-11-16).
Replaces the retired in-process snapshot mechanism
(`watchdog.frame_freeze`'s `snapshot_path` era) for good. See
docs/TROUBLESHOOTING.md "Non-monotonic DTS" for why that mechanism is
known-harmful and must not be resurrected.

## Revision history

- **Revision 1** sourced its sample from the **archive's** in-progress
  segment, which made detection depend on `archive.enabled`. Rejected on
  review ("I really want detection to perform independently of
  archival"); see "Why the archive-reading draft was wrong".
- **Revision 2** introduced the dedicated ring on tmpfs. Its mechanism
  stands.
- **Revision 3** (this one) keeps the mechanism and changes what
  surrounds it, on the strength of measurements made against real
  encodes with this project's own x264 settings:
  1. The central assumption - a stuck source yields identical decoded
     frames across samples - is now **measured**, including how long the
     encoder takes to get there. Revision 2's own evidence did not show
     it: its "content static: hash IDENTICAL" sample pair was read from a
     file whose size had not changed between the two reads (46.4 MB both
     times), so the same bytes were hashed twice.
  2. The reader as specified in revision 2 **returns a valid-looking,
     constant hash when it decodes no frame at all**, which the decision
     logic would count as a freeze. Corrected below.
  3. An alternative that looked better on paper - judging a freeze from
     consecutive frames inside one sample - was tried and **rejected on
     measurement**. Recorded so nobody tries it again.
  4. The detector gains a warn-only mode and a blind alert, both required
     by rules in [ORIENTATION.md](../ORIENTATION.md) that postdate
     revision 2, and uses the solar-aware daytime gate.
  5. The three open design calls are closed.

## Problem statement

A camera/USB fault can leave the device technically responsive but
redelivering stale frames: ffmpeg's `frame=` counter advances, the
progress file stays fresh, and every local health layer reports healthy
while viewers see a frozen image. This blind spot is confirmed real
(three field incidents). The previous attempt to close it - a second
ffmpeg output inside the streaming process - is confirmed harmful (one
total outage, one viewer-visible audio disruption) and has been removed.
The YouTube-side check (`external_check.frame_freeze`) covers this class
only slowly (sampling interval x 2 confirmations, daylight only), and
costs a media fetch from YouTube per sample.

## Core principle

**Detection consumes; it never perturbs.** The detector must not add a
filter, must not emit in bursts, must not be able to fail the stream,
and must not require any cleanup machinery. It writes to RAM, is
self-limiting, and is read by a separate short-lived process.

## Mechanism: a self-limiting ring on tmpfs

A further `tee` branch writes a tiny wrapping segment ring to
`/run/pigeoncam/` (tmpfs, already this project's runtime directory):

```
[f=segment:segment_time=20:segment_wrap=2:segment_format=mpegts:onfail=ignore]/run/pigeoncam/detect/ring%d.ts
```

`segment_wrap=2` means exactly two files ever exist, cycling - no
trimming, no growth, no cleanup timer, nothing to leak. Verified in
revision 2: 45 s of stream produced exactly `ring0.ts` + `ring1.ts`
where an unwrapped segmenter would have produced five files, and the
archive branch running alongside was unaffected.

Steady-state RAM at 6 Mbps CBR: measured 14 to 17 MB per 20 s segment in
revision 3, so about 32 MB of tmpfs for the pair.

When `archive.enabled` is false the stream currently uses a plain
`-f flv` output. With the ring enabled it becomes a two-branch `tee`
(RTMPS + ring), built by the same code path that already builds the
RTMPS + archive `tee`.

Why this is not the mechanism that broke production:

| | retired snapshot output | this ring |
|---|---|---|
| Filter | `-vf fps=1/60` - buffers 59 s, then emits in a burst | **none** |
| Emission | one spike per minute (the DTS cause) | continuous, every frame |
| Muxer | `image2` + `-update 1` - overwrite prompt, needed `-y` (the crash-loop cause) | `segment`, the same muxer family the archive branch has run for weeks |
| Failure containment | none | `onfail=ignore`, same protection the archive branch already relies on |

Both identified failure mechanisms are absent by construction, not by
hope. This is materially lower risk - but see "Honest risk accounting".

## What the detector relies on, measured

The decision rule compares one decoded frame per sample across samples
several minutes apart. That is only sound if a stuck source produces
**bit-identical** decoded frames at different times, through a lossy,
rate-controlled encoder, while a live source never does.

Measured on 2026-11-16 with real ffmpeg and this project's exact encode
arguments (`libx264`, `veryfast`, 6000k with `-minrate`, `nal-hrd=cbr`,
`-g 60 -keyint_min 60`, 1080p30, AAC from `anoisesrc`), 80 s per case,
segmented every 20 s. The source was one of the project's own nest
frames:

| Source | One frame per segment, `-sseof -3` (4 segments) | Reading |
|---|---|---|
| **Stuck camera** - one JPEG looped | `eb04..`, `dd65..`, `dd65..`, `dd65..` | identical from the second segment on |
| **Still scene, live sensor** - same frame + temporal noise | 4 different hashes | never identical |
| **Dim still scene** - darkened, low contrast, faint noise | 4 different hashes | never identical in this run |

Looking at every keyframe of the stuck-camera stream (one per 2 s):

```
seg0   01c2 9a61 74e3 b4c2 4598 2c16 dfb3 4faf a71c 9348 6e5f     all different
seg1   9b0b e1f2 d149 2d44 effc effc effc effc effc effc          converges
seg2   effc effc effc effc effc effc effc effc effc effc          identical
seg3   effc effc effc effc effc effc effc effc effc               identical
```

Three consequences, each of which the design depends on:

1. **The assumption holds.** Once the encoder's rate control has settled
   on unchanging input, successive keyframes decode to identical pixels,
   and stay that way.
2. **It takes about 28 seconds to get there** (14 GOPs here). During that
   window the encoder is still refining the picture and every keyframe
   differs. A sample taken within half a minute of the freeze beginning
   therefore reads as "changed" and costs one sample of detection time.
   This is harmless at a 300 s interval and would be fatal at 20 s:
   `check_interval_seconds` must stay well above the settling time, and
   the implementation must refuse values under 60.
3. **The sample must be a keyframe.** Identity was observed between
   keyframes. `-sseof -N` followed by "first frame decoded" lands on a
   keyframe because decoding can only start at one, which is what makes
   the reader below correct - and why it must not be "improved" into
   picking an arbitrary frame.

Not established by this measurement, and not claimed: that a real stuck
camera redelivers a byte-identical compressed frame. That is the fault
model the three field incidents suggest and the one the YouTube-side twin
has detected in production. A camera frozen in some other way (same
picture, fresh sensor noise) is not a "stuck feed" in this sense and
would not be caught by either check.

## Reading a frame: `-sseof`, validated by size, never `tail | ffmpeg`

```
frame_hash_from_ring <segment_path> <timeout_seconds>
    expected = width * height * 3 / 2          # yuv420p, from camera.resolution
    raw=$(mktemp under the ring directory)
    timeout <t> nice -n 19 ffmpeg -v error -sseof -5 -i <segment_path> \
        -an -frames:v 1 -f rawvideo -pix_fmt yuv420p -y "$raw" 2>/dev/null || { rm; return 0; }
    [ size of "$raw" == expected ] || { rm; return 0; }
    sha256sum < "$raw" | cut -d' ' -f1 ; rm
```

### The empty-frame trap (corrected in revision 3)

Revision 2 piped ffmpeg straight into `sha256sum` under `pipefail` and
treated "empty output" as the failure signal. That signal does not
exist. When ffmpeg opens the file and finds no decodable video frame in
the range it was asked for, it exits **0** having written **nothing**,
and `sha256sum` then produces the hash of zero bytes:

```
$ ffmpeg -v error -sseof -1 -i ring.ts -frames:v 1 -f rawvideo -pix_fmt yuv420p - | sha256sum
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855      pipeline exit 0
```

The condition is precise: **no keyframe lies inside the seek range.**
Measured on a file with a 2-second GOP: `-sseof -1` and `-sseof -1.5`
decode nothing and exit 0; `-sseof -2` and longer decode a frame. A
freshly wrapped, very short ring file is *not* affected (it begins on a
keyframe, and a seek past the start of the file clamps to the start -
verified down to a 20 kB fragment).

That hash is well-formed, non-empty, and **identical on every
occurrence** - so two such reads in a row are, to the decision logic, a
confirmed freeze, followed by a restart and a USB reset of a healthy
camera. Revision 2's default (seek 3 s against a 2 s GOP) stays clear of
it, but only by one second of margin on a configurable key, with a
comment as the sole safeguard; any change to the keyframe interval, or
an operator shortening the seek to "read fresher data", turns the
detector into a generator of false freezes with no error anywhere.

Hence the size check: a decoded 1080p frame is exactly 3,110,400 bytes,
and anything else is "no sample". Checking the byte count rather than
comparing against the known empty hash also rejects a partial frame.
Writing to a temporary file on the same tmpfs, instead of a pipe, is what
makes the size checkable and removes the last pipe from the reader.

The seek is fixed at 5 seconds and is not configurable: it spans two
full GOPs, so a keyframe always lies inside the range; the GOP is
`2 * framerate` frames, i.e. 2 seconds, by construction in
`pigeoncam-stream.sh`; and a knob whose wrong value silently produces
false freezes is not a knob worth offering. (Revision 2's `seek_seconds`
key is dropped.) If the keyframe interval ever becomes configurable, the
seek must be derived from it in the same change.

The same trap exists today in `frame_hash_from_url`, the YouTube-side
reader - see the review backlog, item A11.

### Never `tail | ffmpeg`

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
bug that reaches production.

### Cost

One sample - seek, decode one 1080p keyframe, hash - measured at 0.2 s
of wall time on a 4-core development machine. At one sample every 300 s
the load is negligible even on much slower hardware.

## An alternative that was measured and rejected

Comparing samples minutes apart looks indirect. The obvious
"improvement" is to judge each sample on its own: decode the last two
seconds and call the picture stuck if consecutive frames are identical.
That would cut detection time to a single sample and drop the cross-run
state.

It does not work, on the same three test streams:

| Source | Distinct frames among 60 consecutive | `freezedetect=n=-60dB:d=1` |
|---|---|---|
| Stuck camera | 56 to 60 of 60 | not detected |
| Still scene, live sensor | 60 of 60 | not detected |
| Dim still scene | 60 of 60 | **detected** (false positive) |

Under constant-bitrate encoding x264 spends its surplus bits refining an
unchanging picture, so consecutive frames of a perfectly frozen input
keep differing by small residuals; only the keyframes, each encoded from
scratch, converge. A tolerance-based filter fails in both directions:
it misses the real freeze and fires on dim live footage. The cross-sample
keyframe comparison is not a simplification waiting to be optimised; it
is the form that matches how the encoder behaves.

## Placement: inside the existing watchdog, no new unit

`check_local_frame_freeze()` in `bin/pigeoncam-watchdog.sh` is rewritten
to sample the ring. Rationale: the escalation ladder it needs - plain
restart, then USB reset on recurrence - already lives there, and a
camera-side freeze is precisely the fault class the USB reset exists
for. The watchdog remains a 30-second oneshot; the check only decodes
when its own slower interval has elapsed.

Sampling target: newest `ring*.ts` by mtime. If it yields no sample
(unreadable at that instant, decode timeout), fall back once to the
other file - with `segment_wrap=2` a complete previous segment is always
present. Still nothing after both: "not counted either way", and counted
towards the blind alert below.

**Dependency.** The ladder this feeds is the one the review backlog's
item A1 shows to be unreachable past its first step. Implement A1
first; otherwise a confirmed freeze produces restarts and never a reset.

## Modes: the detector earns its remedy

```
watchdog.frame_freeze.mode: warn      # warn (default) | restart
```

- `warn` - a confirmed freeze calls `notify_escalation
  LOCAL_FRAME_FROZEN` and does nothing else. The tracker is reset after
  notifying, so a persisting condition re-notifies once per
  `confirm_count` fresh samples, not on every watchdog run.
- `restart` - additionally sets `stalled=true, content_frozen=true` and
  enters the existing ladder.

Every detector this project has shipped false-positived in a way nobody
predicted; the border check fired eleven times on twilight frames before
it was understood. This one's remedy includes a physical USB reset. It
starts in `warn`, and the operator promotes it once a few weeks of
journal show no false notifications.

## Blind alert

A detector that cannot read its input must say so. Every due sample that
yields nothing (ring directory missing, both files unreadable, decode
timeout, wrong size) increments `consecutive_ring_failures`; any
successful sample resets it. At every
`watchdog.frame_freeze.sample_failure_alert_after` consecutive failures
(default 10, 0 disables) call `notify_escalation LOCAL_FRAME_SAMPLING_BLIND`,
worded like its YouTube-side counterpart: this reports a blind sensor,
not a broken stream. Same re-arming shape as `note_sample_failure`.

## Gating

| Gate | Rule | Rationale |
|---|---|---|
| Config | `watchdog.frame_freeze.enabled`, default `false` | Opt-in |
| Daytime | `hour_is_daytime "$(current_date_ymd)" <HH>` | Near-dark frames carry too little sensor variation to tell stuck from dark. This is the shared, solar-aware gate the YouTube-side check uses. It reads `archive.daytime_*` even when `archive.enabled` is false - those keys are the project's daytime window, not an archive-only setting. Unfortunate naming, not a coupling |
| Startup grace | `seconds_since_marker started_at` >= `check_interval_seconds` | A just-restarted stream has no baseline, and its encoder has not settled |
| Freshness | newest ring file mtime within `2 x watchdog.check_interval_seconds` | A stale ring means the stream is down - the existing stall path's job; sampling it would double-count one fault as two |
| Interval | `now - last_sample_at >= check_interval_seconds` | Decode cost, and the encoder settling time measured above |

**No gate on `archive.enabled` or `archive.segment_format`.**

## Decision logic

- No sample -> "not counted either way", logged at info, counted towards
  the blind alert. Never evidence of a freeze.
- Hash == previous -> `consecutive_frozen++`; else reset the counter and
  store the new baseline.
- `consecutive_frozen >= confirm_count` -> act according to `mode`.
- After any restart, whoever issued it: clear the tracker. The watchdog
  already does this for its own restarts; a restart by the status check
  or a rotation is covered by the startup-grace gate, which must also
  clear the baseline when it sees `started_at` newer than
  `last_sample_at`.

State fields (`last_sample_hash`, `last_sample_at`,
`consecutive_frozen_samples`, `consecutive_ring_failures`) live in
`watchdog.state`; loss on reboot is correct (fresh baseline).

Time to detect, at the defaults: a freeze is confirmed on the third
sample after it settles (baseline, +1, +2), so between 10 and 15 minutes,
plus up to one further interval if the first sample fell inside the
encoder's settling window.

## Config block

```yaml
watchdog:
  frame_freeze:
    enabled: false
    mode: warn                        # warn | restart - see "Modes"
    ring_dir: /run/pigeoncam/detect   # tmpfs; self-limiting, never needs cleanup
    ring_segment_seconds: 20          # 2 files of this length ever exist
    check_interval_seconds: 300       # minimum 60 - see "What the detector relies on"
    confirm_count: 2
    decode_timeout_seconds: 20
    sample_failure_alert_after: 10    # 0 disables the blind alert
```

`snapshot_path`, `snapshot_interval_seconds` and revision 2's
`seek_seconds` do not exist. `pigeoncam-doctor.sh` gains, when the
feature is enabled:

- FAIL if `check_interval_seconds` is under 60, or `mode` is not one of
  the two values.
- FAIL if `ring_dir` is not on tmpfs (`stat -f -c %T`): the ring is
  rewritten continuously and must not land on flash storage or a disk.
- WARN if the tmpfs holding `ring_dir` has less free space than
  `3 x ring_segment_seconds x encode.bitrate_kbps / 8`, printing the
  computed figure. Exhausting `/run` would be a novel failure mode that
  reaches well beyond this project.

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
~32 MB of RAM and one muxer, not a new failure mode.

## Honest risk accounting

This design re-enters the streaming argv, which the previous one also
did before breaking production twice. The differences are identifiable
and mechanical rather than reassuring generalities (no filter, no burst,
proven muxer, `onfail=ignore`, tmpfs so no disk contention). But
"identifiably lower risk" is not "no risk", and the retired snapshot was
also introduced with a comment claiming zero impact on non-adopters.

What revision 3's measurements do and do not cover: they establish the
detector's logic against real encodes. They say nothing about the ring
branch's effect on a live stream with real audio, which is where the
previous mechanism failed and which no sandbox reproduces.

Therefore: default off, default `warn`, first field enablement follows
the watched-deploy rule (daylight, operator at the console), and the
first thing to check after enabling is
`journalctl -u pigeoncam-stream | grep -c "Non-monotonic DTS"` - if that
count climbs from zero, revert immediately and the design is wrong.

## Work breakdown

**Step 0 - removal (decided 2026-11-16, independent of the rest).**

1. `bin/pigeoncam-stream.sh`: delete the snapshot output block and its
   config reads. `-y` **stays** (independently correct for an unattended
   service); its comment is retitled as history.
2. `bin/pigeoncam-watchdog.sh`: delete `check_local_frame_freeze` and
   its three state fields; an old state file carrying them must still
   load.
3. `config.example.yaml`, `tests/lib/fixtures.sh`,
   `tests/test_config_schema.sh`: the KNOWN-HARMFUL block and its keys
   go. A deployed config still carrying them gets the doctor's existing
   unrecognised-key WARN, which is the right outcome.
4. Tests: snapshot-argv assertions replaced by a negative assertion
   (`-f image2` never in argv, under any setting).
5. `docs/TROUBLESHOOTING.md`: the "Non-monotonic DTS" entry gains a
   closing paragraph - cause removed, entry kept as history.

**Step 1 - the reader**, in `lib/pigeoncam-common.sh`, with its
real-ffmpeg tests. No pipeline change; mergeable alone.

**Step 2 - the ring branch** in `bin/pigeoncam-stream.sh`, behind
`enabled`, with the doctor checks.

**Step 3 - the watchdog check**, `warn` mode and the blind alert. After
the review backlog's item A1.

**Step 4 - `restart` mode** wired into the ladder.

**Step 5 - field enablement**, by the operator, per "Honest risk
accounting".

## Test plan (argv-text tests are insufficient; field-proven)

- **Real-ffmpeg tests** (skip-if-no-ffmpeg, like
  `test_offline_reencode.sh`), generating their own material the way the
  measurements above did - one still image looped for "stuck", the same
  image through `noise=alls=3:allf=t` for "live":
  - a real multi-branch tee: the ring self-limits to exactly two files
    while another branch keeps writing;
  - the reader returns a hash for a complete ring file, and for a ring
    file only a fraction of a second long (the just-wrapped case);
  - the reader returns **nothing** when no keyframe lies in its seek
    range - build that input by encoding with a keyframe interval longer
    than the reader's seek. Piped into `sha256sum` as revision 2 had it,
    the same input yields the empty-input hash with exit status 0. This
    is the regression test for the empty-frame trap and must be seen to
    fail against the revision 2 reader;
  - the reader returns nothing, and does not abort its caller, for an
    empty file and for a missing one;
  - stuck source: keyframe hashes become identical and stay identical
    (poll with a deadline rather than asserting a fixed settling time -
    it depends on resolution and bitrate, and a small test resolution
    settles differently from 1080p);
  - live source: no two samples identical.
- **A regression test pinning the `-sseof` decision**: the
  implementation contains no `tail -c ... | ffmpeg` form and no
  `ffmpeg ... | sha256sum` form in the ring reader, with the evidence
  cited in the test's own comment.
- **Watchdog integration** via the fake ffmpeg: confirm-count ladder in
  both modes, `warn` never issuing a `systemctl` action verb, daytime
  gate, freshness gate, baseline reset after a restart issued by
  another script, no-sample neutrality, the blind alert firing once per
  threshold and re-arming, and inertness when disabled. The fake must
  gain a mode that writes zero bytes and exits 0, since that is what the
  real tool does.
- Every new test verified failing pre-fix before landing.
- Explicitly *not* claimed testable in a sandbox: the ring branch's
  interaction with a real encode and real audio under sustained load.
  The DTS counter check above is the field acceptance test.

## Explicitly out of scope

Any SPEC.md edit (this fits within the existing mandate for stall
detection and USB-reset escalation), and any change to the YouTube-side
check beyond the shared reader fix in the review backlog's item A11.

## Design calls, closed in revision 3

1. **The ring exists only when `frame_freeze.enabled` is true.** An
   always-present ring would make the streaming argv identical for every
   deployment, but imposes 32 MB of `/run` and a muxer on users who never
   asked for the feature, in a project whose last always-on addition to
   that argv caused an outage.
2. **The check lives inside the watchdog.** The ladder is there, process
   isolation from the stream is total either way, and one more unit is
   one more thing to enable, time out and alert on.
3. **The ring is mpegts only.** It is the one format that stays readable
   while being written and after a truncated write; nothing is gained by
   making it configurable.

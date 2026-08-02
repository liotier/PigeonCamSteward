# Design spec: local content-freeze detection from archive segment tails

Status: **specified, not implemented**. Replaces the retired in-process
snapshot mechanism (`watchdog.frame_freeze`'s `snapshot_path` era) for
good. See docs/TROUBLESHOOTING.md "Non-monotonic DTS" for why that
mechanism is known-harmful and must not be resurrected.

## Problem statement

A camera/USB fault can leave the device technically responsive but
redelivering stale frames: ffmpeg's `frame=` counter advances, the
progress file stays fresh, and every local health layer reports healthy
while viewers see a frozen image. This blind spot is confirmed real
(three field incidents). The previous attempt to close it — a second
ffmpeg output inside the streaming process — is confirmed harmful (one
total outage, one viewer-visible audio disruption) and is disabled in
production. The YouTube-side check (`external_check.frame_freeze`)
covers this class only with a ~66-minute floor at production settings
(33-min sampling × 2 confirmations), which the operator has beaten by
hand every single time.

## Core principle

**The detector must share no fate with the data path.** No argv changes
to the streaming ffmpeg, no additional outputs, no shared file
descriptors, no scheduling interaction beyond ordinary OS multitasking
of a niced, short-lived process. The streaming pipeline must be
byte-for-byte identical whether this feature is on or off.

## Key insight

The evidence already exists on disk. The archive tee writes the encoded
stream to `archive.segment_dir` continuously (mpegts, crash-tolerant,
in-progress segment always present while streaming). Decoding one frame
from the newest segment's tail samples *actual delivered content* — the
same pixels viewers see. Nothing new needs to be produced; the check is
a pure consumer.

## Mechanism

New helper in `lib/pigeoncam-common.sh`, mirroring
`frame_hash_from_url`'s exact contract (empty output on any failure,
never a non-zero return — that contract is now written in blood, twice):

```
frame_hash_from_segment_tail <segment_path> <tail_bytes> <timeout_seconds>
    tail -c <tail_bytes> <segment> | nice -n 19 ffmpeg -f mpegts -i pipe: \
        -frames:v 1 -f rawvideo -pix_fmt yuv420p - | sha256sum
    (pipefail-guarded subshell, `|| return 0`, exactly like frame_hash_from_url)
```

Why this works on a growing file: MPEG-TS is a broadcast format —
188-byte packets, PAT/PMT repeated ~10×/second, decoder resync via the
0x47 sync byte is a designed-in capability, not a hack. A tail chunk
needs ≥1 keyframe: GOP is 2 s ≈ 1.5 MB at 6 Mbps CBR, so the default
`tail_bytes` of 8 MiB (~5 s) contains several. The decoded frame is at
most a few seconds older than "now" — irrelevant at multi-minute
sampling.

Hashing decoded pixels (not file bytes) makes segment rollover a
non-event: comparisons remain valid across hourly segment boundaries and
across restarts' new files.

## Placement: inside the existing watchdog, no new unit

`check_local_frame_freeze()` in `bin/pigeoncam-watchdog.sh` is
**rewritten** (not removed) to source its sample from the segment tail
instead of the snapshot file. Rationale: the escalation ladder it needs —
plain restart, then USB reset on recurrence — already lives there, and a
camera-side freeze is precisely the fault class FR7b's USB reset exists
for. Adding a seventh unit would violate the architecture review's own
anti-complexity conclusion. The watchdog remains a 30-second oneshot;
the check only decodes when its own slower interval has elapsed
(state-tracked, as today).

## Gating (all must pass before a sample is taken)

| Gate | Rule | Rationale |
|---|---|---|
| Config | `watchdog.frame_freeze.enabled`, default `false` | Opt-in, as before |
| Archive | `archive.enabled` true **and** `archive.segment_format` = `mpegts` | No segments → no evidence; mp4/mkv tails aren't reliably decodable mid-write. `pigeoncam-doctor.sh` warns if the check is enabled but either condition fails (B-series pattern), and the warning points at the two supported alternatives in "Deployments without an archive" below |
| Daytime | `hour_in_daytime` against `archive.daytime_start/end` | Near-dark frames hash identical legitimately; unchanged rationale, unchanged shared helper |
| Startup grace | `seconds_since_marker started_at` ≥ `check_interval_seconds` | A just-restarted stream has no meaningful baseline |
| Freshness | newest `*.ts` mtime within `2 × watchdog.check_interval_seconds` | A stale segment means the stream is down/stalled — that is the *existing* stall path's job; sampling it would double-count one fault into two detectors |
| Interval | `now − last_sample_at ≥ check_interval_seconds` | Decode cost control |

"Newest segment" = most-recent-mtime `*.<ext>` in `segment_dir`
(`segment_ext_for_format` already exists). No coordination with
archive-trim is needed: trim only touches closed hours (A3), never the
in-progress segment.

## Deployments without an archive

Asked directly during review: **does this function for users who do not
archive?** As a detector, no — and that is structural, not incidental.
With `archive.enabled: false`, `pigeoncam-stream.sh` emits a single
plain `flv` output; no segments exist anywhere, so there is nothing to
sample. The check is inert by design in that configuration (and
`pigeoncam-doctor.sh` says so explicitly rather than leaving it
silently dead).

Making the detector self-sufficient was considered and **rejected**: it
would require adding an output to the streaming process (e.g. a
`segment_wrap` ring written only for detection), which conditions the
live pipeline's argv on a detection feature — the exact coupling class
whose removal motivated this redesign. A detector that can break the
thing it guards is worse than no detector; this project has now proven
that in production twice.

Non-archiving deployments therefore have two supported paths:

1. **The YouTube-side check** (`external_check.frame_freeze`) — works
   with no archive at all, since it samples YouTube's own relay. Its
   detection floor is `check_interval_seconds × (confirm_count + 1)`;
   a non-archiving user who wants faster detection can lower its
   interval at the cost of more frequent yt-dlp/ffmpeg fetches.
2. **Minimal-retention archive** — enable the archive purely as
   detection evidence using knobs that already exist:
   `archive.enabled: true`, `daytime_keep_minutes: 1`,
   `nighttime_discard: true`. Steady-state disk cost at 6 Mbps CBR:
   the in-progress hour (up to ~2.7 GB, transient, trimmed at :05),
   plus ~45 MB retained per daytime hour. Note honestly: retained
   minutes accumulate — there is no total-size or age cap in
   archive-trim (disk headroom is a doctor check, B2, not an enforced
   limit) — so this is ~0.7 GB/day of accumulation a truly
   archive-averse user would need to clear themselves, e.g. a daily
   `find -mtime` cron. No new mechanism is added for this; it is a
   documented use of existing configuration.

## Decision logic (unchanged shape, proven in the YouTube-side twin)

- Empty hash (decode failed) → "not counted either way", logged at
  info. Never evidence.
- Hash == previous → `consecutive_frozen++`; else reset counter, store
  new baseline.
- `consecutive_frozen ≥ confirm_count` → `stalled=true,
  content_frozen=true` → the **existing** ladder: distinct
  `confirmed FROZEN` log line, `STALL_RESTART`, USB-reset escalation on
  recurrence, freeze-tracker reset after any action. State fields
  renamed (`last_sample_hash`, `last_sample_at`,
  `consecutive_frozen_samples`) in `watchdog.state`; tmpfs loss on
  reboot is correct behavior (fresh baseline).

## Config block (replaces the known-harmful one wholesale)

```yaml
watchdog:
  frame_freeze:
    enabled: false
    check_interval_seconds: 300    # sample cadence; MTTD ≈ interval × (confirm_count+1) ≈ 15 min
    confirm_count: 2
    decode_timeout_seconds: 20
    tail_bytes: 8388608            # must span ≥1 GOP; raise if you raise bitrate/GOP
```

`snapshot_path` / `snapshot_interval_seconds` cease to exist. Old keys
in a deployed config are harmlessly ignored (`cfg()` reads only the new
paths); a one-line migration note goes in the config comment. Detection
budget vs. cost: ~15 min MTTD at one niced ~1-second decode per 5
minutes — against the YouTube-side check's 66+ min floor, and against
`Restart=always`'s zero coverage of this class.

## Removal scope (this is half the feature)

1. `bin/pigeoncam-stream.sh`: the entire snapshot output block and its
   config reads — the argv gains nothing from this feature under any
   setting. `-y` **stays** (independently correct for an unattended
   service); its comment is retitled as history.
2. `config.example.yaml`: KNOWN-HARMFUL block deleted, replaced by the
   block above.
3. Tests: snapshot-argv assertions replaced by a **negative** assertion
   (`-f image2` never in argv, under either setting); fixtures/schema
   keys swapped to the new names.
4. `docs/TROUBLESHOOTING.md`: the "Non-monotonic DTS" entry gains a
   closing paragraph — root cause removed entirely, entry retained as
   history.

## Test plan (argv-text tests are insufficient; field-proven this week)

- **Real-ffmpeg, real-tail tests** (skip-if-no-ffmpeg, like
  `test_offline_reencode.sh`): generate a genuine mpegts segment;
  assert (a) tail-decode of a growing/truncated copy yields a hash,
  (b) identical content → identical hash across two samples,
  (c) differing content → differing hash, (d) a tail window with no
  keyframe yields empty, counted neither way.
- **Watchdog integration** via the existing fake-ffmpeg `FRAME_MODE`:
  confirm-count ladder, daytime gate, freshness gate, archive-disabled
  inertness, post-restart baseline reset, decode-failure neutrality —
  the same eight scenarios the snapshot version had, re-pointed.
- Every new test verified failing pre-fix before landing, per standing
  discipline.
- Explicitly *not* claimed testable in a sandbox: scheduler interaction
  with a real encode under load. The design makes that surface as small
  as it can be made (that is the point); first field enablement still
  follows the watched-deploy rule — daylight, operator at the console.

## Explicitly out of scope

Notify wiring (review items 1/5), sustained-INDETERMINATE handling, the
reboot/rotation-age flaw (item 3's territory), any SPEC.md edit (this
fits entirely within FR7/FR7b's existing mandate, same as its
predecessor did).

## Open design calls (operator may veto before implementation)

1. Living **inside the watchdog** rather than as a separate timer unit:
   fewer moving parts won over schedule isolation, since process
   isolation is already total either way.
2. **mpegts-only**: conservative; matroska tails are often decodable in
   practice but this is untested here and not claimed.

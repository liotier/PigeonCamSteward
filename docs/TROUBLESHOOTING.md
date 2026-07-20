# Troubleshooting

Expanded write-ups of every pitfall in the README, with the actual
diagnostic commands and log signatures to look for. See
[SPEC.md §3](../SPEC.md#3-non-goals--explicit-warnings-for-the-readme) for
the source material.

## MJPEG vs YUYV at high resolution/frame rate

**Symptom:** the stream "works" but is choppy, or the watchdog keeps firing
even though nothing looks obviously wrong.

**Cause:** uncompressed YUYV at 1080p is bandwidth-capped by the UVC driver
to roughly 5 fps on USB 2.0. ffmpeg doesn't error — it just delivers frames
at whatever rate the device actually manages, silently.

**Diagnose:**

```bash
v4l2-ctl --list-formats-ext -d /dev/pigeoncam
```

Look under the format your `config.yaml` requests
(`camera.input_format: mjpeg` → the `'MJPG'` block) and confirm the exact
resolution/fps combination you configured is actually listed there — not
just present under a *different* pixel format. `pigeoncam-doctor.sh` checks
this automatically (FR17); run it before assuming your config is fine.

**Fix:** switch to `mjpeg` (the default), or drop resolution/fps until you
find a combination the device actually supports at that pixel format.

## "Preparing stream" hang with no ffmpeg error

**Symptom:** ffmpeg reports perfectly healthy local progress (`-progress`
keeps advancing, no errors in the journal) but the broadcast never leaves
"Preparing stream" in Studio, indefinitely.

**Cause:** a completely silent or absent audio track. This is not a
connection problem, and ffmpeg surfaces no error for it.

**Diagnose:** check `journalctl -u pigeoncam-stream` for the audio input line
in ffmpeg's startup log - confirm `audio.mode` is `synthetic` (the default)
or a genuinely live `real` source, not `off`.

**A field-observed variant that looks identical from the Studio side but
has a different root cause:** YouTube's Stream Health tab can report
"healthy"/"excellent" while the broadcast preview *still* sits at
"Preparing stream" indefinitely. These are evidently two separate
subsystems (transport health vs. broadcast-binding state) - a
healthy-looking health tab does not mean the stream is actually live. If
you hit this with local health AND stream health both looking fine, see
[§ The stuck-broadcast recovery recipe](#the-stuck-broadcast-recovery-recipe-fr15fr7e)
below rather than continuing to assume it's an audio problem.

**Fix:** leave `audio.mode: synthetic` (default) unless you have a
specific reason to change it; if using `real`, confirm the source is
actually producing signal with `pactl list sources` / a quick `parecord`
test.

## A third failure signature: reconnect without exit

**Symptom:** after a deliberate device reconnect (e.g. swapping a USB hub),
ffmpeg logs an error but does *not* exit - it keeps running in an unclear
state, keeps an RTMPS session open at YouTube's ingest, and the only
visible evidence is YouTube later showing a "Stream Ended" dialog once the
process is manually killed. The broadcast never actually shows as live in
the meantime.

**Why the watchdog alone isn't enough here:** local frame-progress (FR7)
can't be trusted to catch this if the frame counter keeps incrementing on
stale or malformed frames. This is exactly why the external, YouTube-side
check (FR7c, `pigeoncam-status-check.sh`) exists as an independent signal
rather than relying solely on ffmpeg's own self-reported health.

**Diagnose:** `journalctl -u pigeoncam-stream` around the time of the
reconnect, cross-referenced with `dmesg -T | grep -iE 'usb|uvc'` - see
[docs/HARDWARE.md](HARDWARE.md#usb-topology) for the three dmesg
signatures worth distinguishing.

## RTMPS vs RTMP

**Symptom:** connection refused, or a URL that looks right but doesn't
work.

**Cause:** the ingest URL must be RTMPS, not RTMP, and it's a *different*
URL from the one Studio shows by default - click the lock icon in Studio to
reveal it.

**Fix:** confirm `youtube.ingest_url` in `config.yaml` starts with
`rtmps://`, not `rtmp://`.

## Real audio mode: a decision checklist, not a vague disclaimer

If you ever enable `audio.mode: real` (as opposed to the default synthetic
noise floor), work through these two questions with a specific answer, not
a general sense that "recording laws vary":

1. **Who has physical access to the space the microphone actually covers?**
   A shared or publicly-visible area is a different risk profile than a
   private space only the operator uses.
2. **Does sound from elsewhere leak into that pickup area** through an open
   window, door, or thin wall?

Both answers can genuinely resolve the concern (solo access to the space,
no indoor leakage through a closed window, for instance) rather than merely
mitigate it. The point is being able to answer both specifically before
flipping to `real` mode.

**Setup, if you do enable it:** capture through PipeWire/PulseAudio by
source name (`pactl list sources short`), never a raw ALSA `hw:`/`plughw:`
device node - the reference deployment hit a `Device or resource busy`
conflict attempting the latter, since the desktop audio server already
holds the device open exclusively (confirm what's holding a specific
device with `sudo fuser -v /dev/snd/pcmC<N>D0c`).

**The session mismatch this almost always hits:** `pigeoncam-stream.service`
runs as root (FR6), which has no PipeWire/PulseAudio session of its own -
those are per-user, listening on `/run/user/<uid>/pulse/native` and
auth'd via that user's own cookie file. `pactl`/`ffmpeg -f pulse` run as
root have nothing to connect to even when `audio.real_source` is
perfectly correct, because they're asking *root's* session, which doesn't
exist. Set **`audio.real_source_user`** to whichever logged-in user's
session actually owns the device (the one `pactl list sources short`
lists it under when *they* run it) - `pigeoncam-stream.sh` and
`pigeoncam-doctor.sh` both bridge into that user's session automatically
(`PULSE_SERVER`/`PULSE_COOKIE`, root can read both regardless of that
user's file permissions) rather than trying to use root's own. If that
user isn't normally logged in when the host boots, their session (and
PipeWire with it) won't be running - `loginctl enable-linger <user>`
keeps it alive persistently without an interactive login, which an
unattended 24/7 deployment needs anyway.

## Stream key handling

A YouTube live stream key is a disposable credential, revocable at will
from Studio - treat it like a low-stakes secret (`chmod 600`, excluded from
git via `.gitignore`), not something requiring password-grade handling. If
you ever suspect it leaked, revoke and regenerate it in Studio; there is no
cleanup beyond that.

## The stuck-broadcast recovery recipe (FR15/FR7e)

**Symptom:** a broadcast stuck at "Preparing stream" with a locally-healthy
stream (ffmpeg's frame progress fine, YouTube's own Stream Health tab
reporting "healthy"/"excellent"), that survives repeated plain restarts of
the streaming service.

**What was tried and did NOT resolve it, in field testing:** repeated plain
restarts, and even a Studio "start new session" click made *from the stuck
broadcast's own management page*. Roughly 20 minutes and multiple attempts,
all unsuccessful.

**What DID resolve it:** fully closing the console and initiating a new
session from the **channel-root** livestreaming URL - not the stuck video's
own URL. This abandons the stuck broadcast's context entirely rather than
trying to continue from it.

The exact server-side mechanism isn't confirmed (total elapsed time and
context-abandonment weren't cleanly isolated during testing), but the
practical recipe holds regardless. Present this to yourself as a manual
last resort, not a guaranteed fix.

**Without Tier 2 enabled** (`tier2.enabled: false`, the default - see
[docs/TIER2.md](TIER2.md) to set it up), this manual recipe is your only
recovery path once `pigeoncam-status-check.sh` logs `ESCALATION_UNAVAILABLE`
and starts backing off its restart cadence. **Tier 2 is the only mechanism
confirmed able to force resolution automatically** - via `liveBroadcasts`'
explicit `transition` to `complete` followed by a fresh `insert`+`bind`,
which doesn't depend on the same implicit session/timeout behavior that
left the manual recipe above unreliable in the first place.

## Reading the logs: telling restart causes apart

Every automatic restart is logged under a distinct label (FR8), on top of
each component already having its own systemd unit (so `journalctl -u
<unit>` isolates it further):

| Label | Emitted by | Meaning |
|---|---|---|
| `STALL_RESTART` | `pigeoncam-watchdog.sh` | Frame progress stalled past `stall_timeout_seconds` (FR7) |
| `USB_RESET_ESCALATION` | `pigeoncam-watchdog.sh` → `pigeoncam-usb-reset.sh` | A stall survived one plain restart; escalated to a USB-level device reset (FR7b) |
| `EXTERNAL_RESTART` | `pigeoncam-status-check.sh` | YouTube-side check confirmed not-live while local health was fine (FR7d) |
| `TIER2_ESCALATION` | `pigeoncam-status-check.sh` | FR7e threshold reached, Tier 2 API recovery attempted |
| `ESCALATION_UNAVAILABLE` | `pigeoncam-status-check.sh` | FR7e threshold reached, Tier 2 not installed - see the recipe above |
| `ESCALATION_BACKOFF` | `pigeoncam-status-check.sh` | Restart cadence backing off per FR7e rather than hammering at the base poll interval |
| `ROTATION_START` / `ROTATION_RESTART` | `pigeoncam-rotate.sh` | Scheduled rotation (FR14), not a failure |
| `ROTATION_SAME_BROADCAST_ID` | `pigeoncam-rotate.sh` | Rotation completed mechanically, but the post-rotation id check found the *same* broadcast id as before - the archive clock likely was NOT reset (SPEC.md §5.4 residual risk) |

```bash
journalctl -u pigeoncam-watchdog -u pigeoncam-status-check -u pigeoncam-rotate --since "-1 day" | grep -E 'STALL_RESTART|USB_RESET|EXTERNAL_RESTART|TIER2_ESCALATION|ESCALATION_|ROTATION_'
```

## Keeping yt-dlp current

`pigeoncam-ytdlp-update.timer` runs `yt-dlp -U` daily as root against the
standalone binary at `/usr/local/bin/yt-dlp` (see the README quickstart's
install step) - not a restart trigger, so it doesn't appear in the FR8
table above.

```bash
journalctl -u pigeoncam-ytdlp-update --since "-1 week"
```

A healthy run logs either `yt-dlp updated: <old> -> <new>` or `yt-dlp
already up to date (<version>)`. Two consecutive real failures (transient
GitHub hiccups aside) are worth investigating directly - `sudo
/opt/PigeonCamSteward/bin/pigeoncam-ytdlp-update.sh` reproduces the same
call by hand with output on your terminal instead of the journal. A stale
binary doesn't fail loudly on its own; it just silently regains the
"distro package lags YouTube's frontend" risk this whole setup exists to
avoid, so it's worth an occasional glance rather than only checking when
`pigeoncam-status-check.sh` (FR7c) starts misbehaving.

## The watchdog and a stopped unit

`pigeoncam-watchdog.sh` runs on a timer (`watchdog.check_interval_seconds`,
default 30s) regardless of whether `pigeoncam-stream.service` happens to
be running at that moment. Before it looks at the progress file at all, it
checks `systemctl is-active pigeoncam-stream.service` and does nothing if
the unit isn't active - logged as "... is not active - nothing to check",
not a restart, not a warning.

This matters because a stopped unit is not a hung one. Three routine cases
leave the unit briefly inactive:

- Restart-mode rotation's (FR14) deliberate stop → gap → start sequence
  (`youtube.rotation.min_gap_seconds`, default 150s) - without this check,
  the watchdog would see the stale progress file mid-gap and restart the
  stream before the gap finished, silently defeating the entire point of
  the gap (resetting YouTube's archive clock).
- systemd cycling between `Restart=always` attempts after a crash.
- An administrator running `systemctl stop pigeoncam-stream` on purpose
  (maintenance, a hardware swap, ...).

If you're watching `journalctl -u pigeoncam-watchdog` during a rotation or
a manual stop and see no `STALL_RESTART`, this is why - it's working as
intended, not silently failing to notice a stall.

## Archive retention rounds to whole hours

`archive.daytime_start`/`daytime_end` accept `HH:MM`, but
`pigeoncam-archive-trim.sh` classifies and processes archive segments one
whole *hour* at a time (its unit of work is "everything named
`YYYYMMDD_HH*`", per FR11's segment-prefix grouping) - it decides, once
per hour, "is this whole hour in or out," never trimming a boundary hour
down to the exact configured minute.

This applies to the shipped default too, not just a hypothetical custom
value: with `daytime_end: "20:30"`, the entire 20:00 hour is still
classified as daytime and trimmed to `daytime_keep_minutes` like any
other daytime hour, not cut off at the 30-minute mark - the boundary hour
rounds *up* to the end time, keeping it daytime rather than partially
discarding it. Symmetrically, a non-hour-aligned `daytime_start` (e.g.
`"04:15"`) rounds the other way: the 04:00 hour is classified as
*nighttime* (its label, `04:00`, is before the configured start), even
though part of that hour is inside the window you configured.

In practice this only means the archive can keep up to just under an hour
past your configured end time before nighttime discarding (or nighttime
trimming, with `nighttime_discard: false`) takes over - worth knowing if
you're sizing storage tightly, but not a bug to chase. If you need a
boundary hour trimmed exactly at the minute, do that by hand after the
fact; the retention job itself works at hour granularity throughout.

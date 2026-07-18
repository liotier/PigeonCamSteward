# Manual verification

`tests/run_all.sh` automates everything that's mechanically testable
without real camera hardware, a real systemd init, or a real YouTube
channel with a persistent stream key. This sandbox/CI environment has none
of those (no `/dev/video*`, systemd not running as PID 1, no YouTube
credentials), and even on a real dev machine, automated tests should not
depend on live network calls to an actual YouTube channel. The gap is
identical in kind to what SPEC.md's own acceptance criterion 7 already
concedes for the USB-reset hardware case: "this is inherently harder to
test reliably than the other criteria here and may require manual/
hardware-dependent verification rather than full CI automation."

This document is the runbook for that remaining gap, checked against a real
deployment.

## What's already automated (`tests/run_all.sh`)

| Criterion | Covered by |
|---|---|
| 1 (doctor flags the four scenarios) | `tests/test_doctor.sh` |
| 4 (watchdog stall detection + restart) | `tests/test_watchdog.sh` |
| 6 (archive-trim retention) | `tests/test_archive_trim.sh` |
| 9 (external-check restart, not USB-reset) | `tests/test_status_check.sh` |
| 10 (rotation grace suppresses spurious alert) | `tests/test_status_check.sh` |
| 12 (tee onfail isolation) | `tests/test_tee_onfail.sh` |
| 13 (distinct segment files, trim groups them) | `tests/test_segment_naming.sh`, `tests/test_archive_trim.sh` |
| 14 (rotation gap timing + id-change detection) | `tests/test_rotate.sh` |
| 15 (indeterminate never restarts) | `tests/test_status_check.sh` |

Criterion 11 (FR7e escalating to the Tier 2 API path) is partially
automated: `tests/test_status_check.sh` verifies the escalation-threshold
counting and the "Tier 2 absent" logging, since that's exactly Tier 1's
observable behavior right now. The actual API-recovery half of that
criterion cannot be verified until Tier 2 (`api/rotate_via_api.py`) exists.

## What needs a real deployment

### Criterion 2: a visible live stream

> `systemctl start nestcam-stream` results in a visible live stream on the
> configured YouTube channel within a reasonable startup window, using only
> `config.yaml` plus the stream key file as inputs.

1. Complete the [README quickstart](../README.md#quickstart) through step 5
   on real hardware with a real, configured stream key.
2. `sudo systemctl start nestcam-stream`
3. `journalctl -u nestcam-stream -f` - confirm ffmpeg starts cleanly, no
   repeated errors.
4. Open `https://www.youtube.com/@<your-handle>/live` - confirm the stream
   goes live within a couple of minutes (allow for YouTube's own
   "Preparing stream" transition latency).

Pass/fail is binary and immediate; there's nothing to automate here without
either a real channel or a mock YouTube ingest server, which would test the
mock, not YouTube's actual behavior.

### Criterion 3: `Restart=always` recovery

> Killing the ffmpeg process (`kill -9`) results in automatic recovery via
> `Restart=always` within the configured `RestartSec`.

Requires a real systemd instance as PID 1 (this sandbox's systemd is not
running as init - `systemctl status` returns "Host is down"). On the
deployment host:

```bash
sudo systemctl start nestcam-stream
sleep 5
FFMPEG_PID=$(systemctl show -p MainPID --value nestcam-stream)
sudo kill -9 "$FFMPEG_PID"
sleep 15   # RestartSec=10 (default) + startup margin
systemctl is-active nestcam-stream   # expect: active
systemctl show -p MainPID --value nestcam-stream   # expect: a NEW pid, different from $FFMPEG_PID
```

Also worth confirming FR6's actual point: simulate a *rapid* failure burst
(e.g. temporarily point `camera.device` at a nonexistent path and restart
the unit several times within a few seconds) and confirm the unit keeps
retrying rather than landing in `failed`/`start-limit-hit` - that's what
`StartLimitIntervalSec=0` is for, and `nestcam-doctor.sh`'s FR6 check only
confirms the *setting* is present in the unit file, not that systemd
actually honors it end-to-end on this host.

### Criterion 5: rotation produces a new broadcast/VOD

> The rotation timer fires at the configured interval and a new
> broadcast/VOD appears in the channel's content list without manual
> intervention, given a persistent/reusable stream key.

`tests/test_rotate.sh` already verifies `nestcam-rotate.sh`'s own
mechanics in full (stop→gap→start timing, pre/post id logging) against a
mocked `systemctl`/`yt-dlp`. What it cannot verify is YouTube's actual
server-side behavior. On a real deployment:

1. Confirm your stream key is in reusable/persistent mode in Studio (the
   tool cannot verify this remotely - see
   [SPEC.md §5.4](../SPEC.md#54-broadcast-rotation-12-hour-archive-workaround)).
2. For a faster test than waiting out the real `11h45m` default, temporarily
   lower `youtube.rotation.interval` (e.g. to a few minutes) and
   `min_gap_seconds` stays at its configured value - `daemon-reload` +
   restart `nestcam-rotate.timer` after editing.
3. `journalctl -u nestcam-rotate -f` and watch for `ROTATION_START`,
   `ROTATION_RESTART`, and then either `ROTATION_NEW_BROADCAST_ID` (pass)
   or `ROTATION_SAME_BROADCAST_ID` (the SPEC.md §5.4 residual risk - not a
   tooling bug, but worth knowing about *before* relying on it for a whole
   season).
4. Confirm in YouTube Studio's content list that a new broadcast/VOD
   actually appears.
5. Revert the interval back to `11h45m` (or your intended value) afterward.

### Criterion 7: USB-level device reset on real hardware

SPEC.md's own acceptance criteria already flag this one as inherently hard
to automate ("may require manual/hardware-dependent verification"). What IS
automated: `tests/test_watchdog.sh` verifies the *decision logic* (escalate
after exactly one failed plain restart, not zero or two) and that
`nestcam-usb-reset.sh` is actually invoked and actually calls its
configured tool, using a fake `uhubctl` that always succeeds. What it
cannot verify is a real device recovering from a real wedged-but-enumerated
state. To check that for real, you need a way to reliably wedge a UVC
device on demand, which SPEC.md itself notes doesn't exist deterministically
- practically, this means watching for it in the field
(`journalctl -u nestcam-watchdog`) rather than provoking it in a test.

### Criterion 8: `/live` redirect stability

> Regardless of rotation precision or timing, `https://www.youtube.com/@<handle>/live`
> resolves to whatever broadcast is currently live at any point during a
> rotation cycle.

This is really a property of YouTube's own redirect behavior, not this
project's code - confirm it once against your real channel during/after a
real rotation (criterion 5's manual test above already exercises this: just
also check the `/live` URL resolves correctly throughout).

## Summary

Once you've completed the manual checks above against a real deployment,
Tier 1's acceptance criteria 1-6 and 12-15 are all confirmed - the required
scope for this implementation pass. Criteria 7, 8, and 11 have partial
automated coverage with the remainder either hardware-dependent (7) or
observational (8), and criterion 11's full scope (an actual Tier 2 API
recovery) is blocked on Tier 2 not existing yet.

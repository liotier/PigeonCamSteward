# nestcam-streamer

A configurable toolkit for unattended, long-duration (multi-week) 24/7
livestreaming of a low-motion subject — a wildlife nest camera is the
reference use case — from a single fixed USB webcam to YouTube Live, on
modest or older Linux hardware. Built on ffmpeg + systemd, not OBS: there's
no compositor work to justify for a static single-source feed.

The reference deployment (this repository) is a wood pigeon (*Columba
palumbus*) nest camera on a residential balcony. Every default is
overridable via `config.yaml`, so the toolkit works for other subjects,
cameras, and hardware too. Full design rationale lives in [SPEC.md](SPEC.md);
this file is the practical quickstart.

**Status:** both tiers are implemented. Tier 1 (§2.1 in-scope core):
capture/encode/stream, the frame-progress watchdog with USB-reset
escalation, the external YouTube-side live-status check, restart-mode
broadcast rotation, local archival with retention, and the doctor script.
Tier 2 (§5.4.1, `api/rotate_via_api.py`): YouTube Data API rotation and the
FR7e last-resort recovery path. Tier 1 is fully functional without Tier 2;
see [§ Tier 2](#tier-2-optional) below and [docs/TIER2.md](docs/TIER2.md)
for setup.

## Read this before you build anything

Lessons from the reference deployment that cost real debugging time.
Full detail and diagnostic commands: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

- **Use MJPEG, not YUYV, at 1080p30+ over USB 2.0.** Uncompressed YUYV at
  1080p is bandwidth-capped by the UVC driver to ~5 fps on USB 2.0. This
  fails *silently* — capture "works," just at an unannounced low frame
  rate. Run `nestcam-doctor.sh` before your first stream; it checks this.
- **A silent or absent audio track can leave YouTube stuck at "Preparing
  stream" indefinitely**, with no error from ffmpeg. This is not a
  connection problem. Default `audio.mode: synthetic` (a very-low-amplitude
  noise floor) avoids it; `audio.mode: off` is deliberately supported but
  **not recommended** for exactly this reason.
- **Use RTMPS, not RTMP**, for the YouTube ingest URL — a different URL
  from the one Studio shows by default (click the lock icon to reveal it).
- **USB topology matters more than USB spec.** Bus-powered hub chains and
  marginal power budgets are a common source of unexplained overnight
  disconnects. See [docs/HARDWARE.md](docs/HARDWARE.md).
- **A live stream key is a disposable credential**, revocable at will from
  Studio — treat it as a low-stakes secret (chmod 600, don't commit it),
  not something requiring password-grade handling.
- **Share `https://www.youtube.com/@<handle>/live`, never a specific video
  URL.** Broadcast rotation (below) does not guarantee a stable video ID;
  the `/live` redirect always resolves to whatever is currently live, so
  rotation is a non-issue for viewers regardless of which rotation tier is
  in use.

## Architecture

Three independent control loops around the core ffmpeg process, plus two
verification/escalation steps layered on top:

1. **systemd `Restart=always`** recovers from ffmpeg *exiting*.
2. **The watchdog** (`nestcam-watchdog.sh`, FR7) recovers from ffmpeg
   *hanging while still running* — a failure `Restart=always` can't see. A
   stall that survives one plain restart escalates to a USB-level device
   reset (`nestcam-usb-reset.sh`, FR7b) before retrying.
3. **The rotation timer** (`nestcam-rotate.sh`, FR14) is a deliberate,
   scheduled restart to stay under YouTube's ~12h continuous-archive
   ceiling — a policy action, not a failure recovery, kept deliberately
   separate from the watchdog.
4. **The external status check** (`nestcam-status-check.sh`, FR7c/d/e)
   verifies YouTube itself is actually broadcasting — a signal none of the
   above can see, since the "Preparing stream" hang looks perfectly healthy
   locally. Classifies every poll as confirmed-live, confirmed-not-live, or
   indeterminate, and only confirmed-not-live can trigger a (plain) restart.

Full diagram and reasoning: [SPEC.md §4](SPEC.md#4-architecture-overview).

## Quickstart

### 1. Install dependencies

```bash
sudo apt update
sudo apt install -y ffmpeg v4l-utils usbutils procps jq uhubctl yq shellcheck
```

`yq` here is the [kislyuk/yq](https://github.com/kislyuk/yq) wrapper around
`jq` (same package name on Debian/Ubuntu) — every script reads
`config.yaml` through it. This is one addition beyond the dependency table
in [SPEC.md §6a](SPEC.md#6a-system-dependencies); everything else there
matches exactly.

`yt-dlp` is deliberately **not** installed via apt (it tracks YouTube's
frontend closely; a distro-packaged version can lag and silently misparse
the page):

```bash
pip install --break-system-packages yt-dlp
```

### 2. Place the project and the udev rule

Packaging (a proper `.deb`, or a Python package for Tier 2 only) is a
later step — for now, clone or copy this repository to `/opt/PigeonCamSteward`
(the path the shipped systemd units assume; edit the `ExecStart=` lines in
`systemd/*.service` if you place it elsewhere).

**Ownership:** own the checkout as yourself, not root - `git pull` and any
script tinkering then don't need `sudo` each time, and it costs nothing
security-wise since the systemd units below run as root regardless of who
owns the files they exec (root can always read/execute them; that's
independent of ownership). What *should* stay `root:root` is `/etc/nestcam`
(step 3) - the stream key and any Tier 2 credentials - since a
`600`-mode file you own is readable by anything running as you, while a
root-owned one needs an actual privilege-escalation step even from a
compromised process running as you.

```bash
sudo mkdir -p /opt/PigeonCamSteward
sudo chown "$USER":"$USER" /opt/PigeonCamSteward
git clone https://github.com/liotier/PigeonCamSteward.git /opt/PigeonCamSteward
# Add -b <branch-name> if the code you want isn't on the default branch yet.

sudo cp /opt/PigeonCamSteward/udev/99-nestcam.rules.example /etc/udev/rules.d/99-nestcam.rules
# edit it with your camera's idVendor/idProduct (see the comments in the file), then:
sudo udevadm control --reload
sudo udevadm trigger
ls -l /dev/nestcam   # should now exist
```

To pick up later changes: `cd /opt/PigeonCamSteward && git pull`.

### 3. Configure

```bash
sudo mkdir -p /etc/nestcam
sudo cp /opt/PigeonCamSteward/config.example.yaml /etc/nestcam/config.yaml
sudo $EDITOR /etc/nestcam/config.yaml   # at minimum: youtube.ingest_url, external_check.channel_live_url

# your YouTube stream key - a disposable, Studio-revocable credential, but
# keep it out of git and off multi-user hosts casually anyway:
sudo mkdir -p /etc/nestcam
echo 'your-stream-key-here' | sudo tee /etc/nestcam/stream_key >/dev/null
sudo chmod 600 /etc/nestcam/stream_key
```

Full schema and every default: [config.example.yaml](config.example.yaml)
(comments inline) and [SPEC.md §8](SPEC.md#8-configuration-schema-illustrative--claude-code-should-treat-this-as-a-starting-draft-not-a-frozen-contract).

**Storage sizing:** the project deliberately doesn't auto-compute or
enforce a storage budget — drive sizes vary too much to hardcode. Run
`nestcam-doctor.sh` (next step) to see the formula and a current estimate
for *your* config before committing to a retention window; a 6 Mbit/s
stream kept 16.5 daytime hours a day is on the order of 40+ GB/day.

### 4. Run the doctor script

```bash
sudo NESTCAM_CONFIG=/etc/nestcam/config.yaml /opt/PigeonCamSteward/bin/nestcam-doctor.sh
```

Fix everything it flags before proceeding — it exists specifically to catch
the failure modes in [§ Read this before you build anything](#read-this-before-you-build-anything)
before they cost you a debugging session. FR6's systemd start-limit check
will WARN (not FAIL) until step 5 installs the unit file.

### 5. Install and start the systemd units

```bash
sudo cp /opt/PigeonCamSteward/systemd/nestcam-*.service /opt/PigeonCamSteward/systemd/nestcam-*.timer /etc/systemd/system/
sudo cp /opt/PigeonCamSteward/systemd/nestcam-tmpfiles.conf /etc/tmpfiles.d/nestcam.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/nestcam.conf
sudo systemctl daemon-reload

sudo systemctl enable --now nestcam-stream.service
sudo systemctl enable --now nestcam-watchdog.timer
sudo systemctl enable --now nestcam-status-check.timer
sudo systemctl enable --now nestcam-rotate.timer
sudo systemctl enable --now nestcam-archive-trim.timer
```

Watch it come up:

```bash
journalctl -u nestcam-stream -f
```

Then confirm on `https://www.youtube.com/@<your-handle>/live`.

**Note:** the timer files' `OnUnitActiveSec=`/`OnCalendar=` values mirror
`config.yaml`'s defaults (`watchdog.check_interval_seconds`,
`external_check.poll_interval_seconds`, `youtube.rotation.interval`) but are
not read *from* config.yaml — if you change one of those, update the
matching `systemd/*.timer` file too and re-run `daemon-reload`.

### 6. Re-run the doctor script

Now that the unit is installed, `nestcam-doctor.sh` can check FR6's
start-limit setting for real:

```bash
sudo NESTCAM_CONFIG=/etc/nestcam/config.yaml /opt/PigeonCamSteward/bin/nestcam-doctor.sh --unit-file /etc/systemd/system/nestcam-stream.service
```

### 7. (Optional) Tier 2

Everything above is a complete, working deployment on Tier 1 alone. If you
want overlap-free scheduled rotation or the FR7e stuck-broadcast recovery
path, see [§ Tier 2](#tier-2-optional) below and
[docs/TIER2.md](docs/TIER2.md).

## Testing

```bash
tests/run_all.sh
```

Runs shellcheck plus every automated check this project has: config schema
validation, and functional tests against real `ffmpeg` (tee-muxer failure
isolation, segment naming/rotation) and mocked external tools (`v4l2-ctl`,
`yt-dlp`, `systemctl`, `uhubctl`) for everything that needs a camera,
network, or systemd it can't assume exists in CI. What's covered and what
genuinely needs a manual run against real hardware and a real YouTube
channel: [tests/MANUAL_VERIFICATION.md](tests/MANUAL_VERIFICATION.md).

## Tier 2 (optional)

`api/rotate_via_api.py` implements
[SPEC.md §5.4.1](SPEC.md#541-tier-2-api-call-sequence-reference-implementation-for-apirotate_via_apipy)'s
YouTube Data API call sequence: explicitly `transition` the outgoing
broadcast to `complete`, `insert` + `bind` a new one to your persistent
stream, wait for `streamStatus=active`, then `transition` the new broadcast
to `live`. It's optional and off by default (`tier2.enabled: false`) — full
setup walkthrough: [docs/TIER2.md](docs/TIER2.md).

Two independent things it unlocks, gated separately (`youtube.rotation.mode`
picks how *routine* rotation happens; `tier2.enabled` gates whether Tier 2
is available *at all*, including for recovery — see the table in
[docs/TIER2.md](docs/TIER2.md#what-each-mode-actually-does)):

- **`youtube.rotation.mode: api`** — overlap-free scheduled rotation with
  custom title/description/category per broadcast, replacing FR14's
  restart-based default. Requires `tier2.enabled: true`; setting `api` mode
  without it fails loudly at rotation time rather than silently falling
  back to `restart`.
- **FR7e last-resort recovery** — once `nestcam-status-check.sh` hits
  `max_restarts_before_escalation` consecutive not-live restarts, it
  attempts Tier 2's recovery sequence if `tier2.enabled: true` (logging
  `TIER2_ESCALATION`), or logs a clear "manual Studio intervention may be
  required" message and backs off its restart cadence if not
  (`ESCALATION_UNAVAILABLE`) — this works independently of
  `youtube.rotation.mode`.

**Tier 2 is strongly recommended for unattended deployments running more
than a day or two unsupervised**, specifically for the recovery path:
field testing reproduced a broadcast stuck at "Preparing stream" that
survived repeated plain restarts and only resolved by abandoning the
broadcast context entirely — the kind of stuck state only Tier 2's
explicit `transition`/`bind` sequence can force past. See
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#the-stuck-broadcast-recovery-recipe-fr15fr7e)
for the manual recipe if you'd rather not set Tier 2 up.

## Deployment / packaging

Not implemented yet, by design — see the quickstart above for the manual
install path. This is almost entirely shell scripts + systemd units + udev
rules, which is a poor fit for Python packaging (pip/pipx target
site-packages or a venv, not `/etc/systemd/system`); a Debian package is
the architecturally correct long-term fit (native systemd/udev integration)
but real ongoing overhead for what's currently a single reference
deployment. Revisit once the file layout has had a season of real use.

## License

[The Unlicense](LICENSE) (public domain). `ffmpeg`, `v4l-utils`, `uhubctl`,
`yt-dlp`, and `jq`/`yq` are all invoked as separate subprocesses; Tier 2's
Google API client libraries (`google-api-python-client`,
`google-auth-httplib2`, `google-auth-oauthlib`) are genuine Python imports
but Apache-2.0. Neither pattern propagates a copyleft requirement here.

`SPEC.md`'s own change history states "License: GPLv3" from an earlier
planning pass; the license actually shipped in this repository is The
Unlicense, per the repository owner.

## Further reading

- [SPEC.md](SPEC.md) — the full technical specification this
  implementation is built against.
- [docs/HARDWARE.md](docs/HARDWARE.md) — camera/USB topology/autofocus/
  outdoor deployment guidance.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — expanded write-ups
  of every pitfall above, with diagnostic commands and log signatures.
- [docs/TIER2.md](docs/TIER2.md) — Tier 2 setup: Google Cloud Console OAuth
  client, venv, one-time authorization, finding your persistent stream id.
- [tests/MANUAL_VERIFICATION.md](tests/MANUAL_VERIFICATION.md) — acceptance
  criteria that need real hardware/YouTube and can't be claimed as passing
  from an automated run.

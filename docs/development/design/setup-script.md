# Design spec: `bin/pigeoncam-setup.sh`

Status: **specified, not implemented.**

An interactive, re-runnable script that fills in `/etc/pigeoncam/config.yaml`
by asking questions, so a new operator does not have to read a 438-line
config file before their first stream.

## Why a standalone script, and not `postinst`

Decided, with reasons that are about this project rather than packaging
etiquette:

- **`postinst` frequently runs where nobody can answer.** Unattended
  upgrades, container builds, `DEBIAN_FRONTEND=noninteractive`, preseeded
  installs. A script that blocks on a prompt hangs all of them.
- **Doing it properly from `postinst` means debconf** - template files,
  translations, and a separate step to write the answers into the config.
  Large machinery for one config file.
- **Most of the answers do not exist at install time.** The stream key
  needs a visit to YouTube Studio. `external_check.channel_live_url` needs
  a channel to exist. `camera.device` needs the udev rule, which needs the
  camera's vendor and product IDs. An install-time wizard would mostly
  collect "I do not know yet".

So: a script the operator runs **when they are actually ready**, working
identically whether the project arrived by `git clone` or by `apt`. A
package's `postinst` prints "run `pigeoncam-setup.sh` next" and nothing
more.

## The constraint that decides the implementation

`config.example.yaml` is **438 lines, of which 323 are comments.** Those
comments are the project's real configuration documentation - every
non-obvious default is explained where it is set, and several carry
field-earned warnings (`KNOWN-HARMFUL AS SHIPPED` on
`watchdog.frame_freeze`, the daily-recurrence trap, the yt-dlp staleness
reasoning).

A `yq` round-trip **destroys all of them** - verified:
`yq -y . config.example.yaml` emits a clean, comment-free file. So does
any implementation that parses to a data structure and re-serialises.

**Therefore: the script must edit values in place, never regenerate the
file.** Concretely, for each answer, rewrite only the one line matching
that key at its known indentation, leaving everything else - comments,
ordering, blank lines, unrelated keys - byte-identical.

A `sed`-style targeted substitution anchored on the key and its
indentation is the intended approach. Whatever is used must be verified
by a test asserting that the comment count is unchanged after a run.

## Behaviour

### Invocation

```
pigeoncam-setup.sh [--config PATH] [--non-interactive] [--answers FILE]
```

- Default config path is the same one every other script uses
  (`$PIGEONCAM_CONFIG`, else `/etc/pigeoncam/config.yaml`).
- If that file does not exist, offer to create it from
  `config.example.yaml` and continue. If it does exist, edit it in place.
- **Re-runnable.** Every prompt offers the *current* value from the config
  as its default, so a second run is a review pass, not a restart. Pressing
  Enter always keeps what is already there.
- **Back up before writing:** copy to `config.yaml.bak-<timestamp>` and say
  so. Only write once all questions are answered, never incrementally, so
  an abandoned run (Ctrl-C) changes nothing.

### `--non-interactive` / `--answers FILE`

Required for the test suite, and useful for a second identical
deployment. `--answers` reads `key=value` lines using the same dotted key
names as the config. `--non-interactive` without `--answers` makes every
question take its current value, which reduces to a no-op that still
exercises the write path. In non-interactive mode an unanswerable
required question is an error naming the key, never a silent default.

### The questions, in order

Each shows the current value, accepts Enter to keep it, and validates
before moving on.

| # | Key | Notes |
|---|---|---|
| 1 | `camera.device` | Offer `v4l2-ctl --list-devices` output. Warn (do not block) if the path does not exist - the udev rule may not be in place yet. |
| 2 | `camera.input_format`, `camera.resolution`, `camera.framerate` | If the device exists, offer the combinations `v4l2-ctl --list-formats-ext` actually reports and let the operator pick one. **Never offer a YUYV mode at 1080p** without repeating the silent-5fps warning. |
| 3 | `youtube.ingest_url` | Default `rtmps://a.rtmps.youtube.com/live2`. Reject a plain `rtmp://` URL with the reason. |
| 4 | *stream key* | Written to `/etc/pigeoncam/stream_key`, `chmod 600`, **never into config.yaml**. Read without echoing. Skip if the file already exists, unless the operator asks to replace it. |
| 5 | `external_check.channel_live_url` | Ask for the handle and build `https://www.youtube.com/@<handle>/live`. Reject a `watch?v=` URL, explaining that a specific video id breaks on rotation. |
| 6 | `archive.segment_dir` | Warn if the filesystem has less headroom than `pigeoncam-doctor.sh`'s own estimate for the answers given so far. |
| 7 | `location.latitude`, `location.longitude` | Optional. Explain in one line what setting them enables (solar scheduling and the daylight gates). Accept empty. Validate ranges. **Never guess or geolocate.** |
| 8 | `notify_command` | Optional but **actively encouraged** - say plainly that leaving it empty means every alert reaches only the system journal, and that a whole season ran that way before anyone noticed a blind health check. Offer to send a test notification if one is given. |
| 9 | `youtube_api.enabled` | Ask yes/no. On yes, do **not** attempt the OAuth flow - print the two commands from `docs/YOUTUBE-API.md` and continue. |

### On finishing

Print, in order: what changed, where the backup went, and then
`pigeoncam-doctor.sh` as the required next step. Do **not** run the
doctor automatically - its output deserves to be read, not scrolled past
at the end of a wizard. Do not enable or start any unit.

## Non-goals

- Not a TUI. Plain prompts on a terminal, readable over a serial console.
- Does not write the udev rule (needs vendor/product IDs the operator must
  confirm) or touch systemd.
- Does not validate the stream key against YouTube.
- Does not replace `config.example.yaml` as the reference. Anything it
  does not ask about stays at its documented default, with the comment
  explaining it still present - which is the whole point of editing in
  place.

## Tests (`tests/test_setup.sh`)

All via `--non-interactive --answers`, against a temp config:

1. **Comments survive.** Comment-line count and total line count are
   unchanged after a run that alters several values. This is the
   headline test - it is what stops someone "simplifying" the writer into
   a `yq` round-trip later.
2. **Only the intended lines change.** `diff` against the input shows
   exactly the answered keys and nothing else.
3. **Idempotent.** Running twice with the same answers produces a file
   identical to running once.
4. **Enter keeps the current value** - an unanswered key is byte-identical
   afterwards.
5. **The stream key never lands in `config.yaml`**, does land in its own
   file, and that file is mode 600.
6. **Validation rejects** `rtmp://`, a `watch?v=` channel URL, and an
   out-of-range latitude, each naming the reason.
7. **A backup is written**, and its content equals the pre-run file.
8. **Abandoning changes nothing** - a run that fails validation in
   non-interactive mode leaves the config byte-identical.
9. **A missing config** is created from `config.example.yaml` rather than
   from an internal template that could drift from it.

## Open question

Whether `pigeoncam-ctl.sh` should grow a `setup` verb pointing at this,
or whether a second entry point is clutter. Not decided; either is fine
and the script works standalone regardless.

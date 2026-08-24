# Orientation

What a newcomer to this codebase needs to know before changing anything.
The [working agreements](README.md#working-agreements) next door say what
the rules are; this says how the thing is actually built and why it looks
the way it does.

There has only ever been one deployment and one maintainer, so nothing
here is policy handed down from a committee — it is a description of what
the project settled into over a season of running unattended. Where a
convention exists because something broke, that is said plainly.

---

## The shape of it

Bash, systemd, and a udev rule. One optional Python component
(`api/rotate_via_api.py`) for the YouTube Data API, isolated in its own
venv and never required.

**One long-running service, five oneshot timers.** `pigeoncam-stream.service`
runs ffmpeg and is the only thing that stays up. Everything else —
watchdog, status check, rotation, archive trim, yt-dlp update — is a
oneshot that systemd fires on a timer, does its work in a second or two,
and exits. There is no daemon, no supervisor process, and no long-lived
shared state.

That has a consequence worth internalising: **every invocation re-reads
`config.yaml` from scratch.** A config change takes effect on the next
firing with no restart and no reload. The exception is the two timer
intervals duplicated into `systemd/*.timer` files (`OnUnitActiveSec=`),
which systemd owns and config cannot reach — `pigeoncam-doctor.sh` warns
when those drift apart, because they have.

**`lib/pigeoncam-common.sh` is sourced by everything.** Config access,
logging, the escalation notifier, marker files, the solar helpers, the
frame-fetch helpers, and the `ERR` trap all live there. If you are adding
something two scripts need, it goes here.

**State lives in marker files, not memory**, in two flavours that are not
interchangeable:

| Helper | Location | Survives reboot | Use for |
|---|---|---|---|
| `marker_path` | `/run/pigeoncam/` (tmpfs) | no | "when did this process last start" |
| `durable_marker_path` | `/var/lib/pigeoncam/` | yes | "when did we last rotate" |

Getting that wrong is not academic: rotation's age check has to survive a
reboot or a reboot mid-broadcast strands it past YouTube's archive
ceiling, which is the whole reason the project exists.

---

## Particularities that will surprise you

**`cfg()` deliberately does not use jq's `//` operator.** `//` treats a
real `false` the same as missing, which would silently coerce every
false-valued boolean into its default. Read the value and test it for
emptiness instead. `cfg_bool` exists for the boolean case.

**`awk` must be mawk-safe.** `/usr/bin/awk` is mawk on Debian, so no
gawk-only syntax — notably no three-argument `match()`. The solar maths in
`lib/pigeoncam-solar.sh` is a real awk program under this constraint.

**A feature that cannot run falls back; it never blocks.** Every optional
mode follows the same shape: if its prerequisite is missing or
unparseable, log exactly one warning, fall back to the simple behaviour,
and carry on. Solar scheduling without coordinates reverts to the plain
interval. A misconfigured detector does not get to stop the camera
streaming. `pigeoncam-doctor.sh` is where a misconfiguration gets
reported loudly, because that is a place a human is already looking.

**Detection consumes; it never perturbs.** A health check must not be able
to damage the thing it watches. This one is written in blood: a
freeze-detector that added a second output to the running ffmpeg process
caused audio timestamp bursts that viewers saw as the stream cutting in
and out, and it is still disabled and marked `KNOWN-HARMFUL AS SHIPPED` in
`config.example.yaml`.

**Health checks never act on "indeterminate".** The external check
classifies every poll as confirmed-live, confirmed-not-live, or
indeterminate, and only confirmed-not-live may trigger anything. A network
blip must not be able to start a restart storm. Do not add a fourth
outcome that acts.

**New detection ships off, or in a warn-only mode.** Both frame checks
default off; `frame_border` defaults to `warn` even once enabled. Detectors
false-positive in ways nobody predicts — the border check fired eleven
times on dim twilight frames before anyone understood why — so they earn
their remedy in the field rather than arriving with it.

**Every detector needs an answer to "how would we know if this stopped
working?"** Two health layers went completely blind for three and a half
days while the doctor reported everything green, because the alert for
that class had been attached to the one sensor that had failed before
rather than to the pattern. If you add a check, add its blind alert in the
same change.

**`pigeoncam-doctor.sh` distinguishes WARN from FAIL on one axis:** is the
finding ambiguous? An unrecognized config key might be a typo or might be
intentional — WARN. A duplicated key silently discards a value the
operator set — FAIL. A disk filling up is the operator's call — WARN. A
camera that cannot deliver the configured format — FAIL.

**A path you print is either a program or a document, and they do not
always live together.** Name a program (`api/rotate_via_api.py`,
`config.example.yaml`) with `$PIGEONCAM_PROJECT_ROOT`; name a document
(`docs/*.md`, `README.md`, `SPEC.md`, the udev example) with
`$PIGEONCAM_DOC_DIR`. A git clone and the `/opt` install keep both in one
tree, so the two are the same directory and getting it wrong looks
completely fine — the Debian package is the shape that pulls them apart,
and there the wrong one names a file that is not there. This is not
hypothetical: it was live in 24 messages across six scripts, invisible to
the entire suite, and only surfaced when the built `.deb` was installed
and its wizard actually run. `tests/test_makefile.sh` now resolves every
such path against a split install, so a new one gets caught immediately.

**Bash hazards this project has actually been bitten by** are listed in
the [working agreements](README.md#working-agreements) and dissected in
[INCIDENTS.md](INCIDENTS.md). The short version: bare `x=$(...)` under
`set -e`, `main "$@" || ...`, a conditional as a function's last statement,
and leading-zero values parsed as octal. All four shipped to production.

**A default that decides where the operator's data lives is a decision
you are making on their behalf.** `archive.segment_dir` used to default to
`/var/lib/pigeoncam/archive`. That reads as a harmless convenience and is
not one: `/var/lib` is where a *program* keeps its own state, a package
manager may clear it on purge, and the operator who never read that config
line had irreplaceable footage written there without ever choosing it. It
now has no default and is required whenever archiving is on — doctor
FAILs, the stream service refuses to start, the wizard asks. When a
setting's right value is genuinely site-specific (which disk has the
room?), "required" is better than a guess that looks like an answer.

**A test that reads an absolute system path is not isolated**, even when
it only reads. `tests/test_setup.sh`'s ninth scenario asserted a failure
that depended on `/etc/pigeoncam/stream_key` being absent — true on a
build machine, false on the deployment host, which is precisely where an
operator is told to run `make check`. Fixtures redirect such paths into
`$WORK`; where a scenario genuinely needs the shipped default (that one
copies `config.example.yaml` untouched, which is the point of it), assert
the invariant that holds either way and let the outcome follow the host.

---

## The test harness

```bash
tests/run_all.sh            # everything — this is the gate
tests/test_<area>.sh        # one area, much faster while iterating
tests/shellcheck.sh         # lint only
```

The suite takes several minutes and is subprocess-bound rather than
compute-bound: every `cfg()` call spawns `yq`, and the tests run the real
scripts end to end. That is a deliberate trade — it catches things a
mocked config never would.

**Fakes, not mocks.** `tests/fixtures/fake-bin/` holds stand-ins for
`ffmpeg`, `yt-dlp`, `systemctl`, `systemd-run`, `v4l2-ctl`, `uhubctl`,
`pactl`, `df`, `crontab`, `udevadm`. They are put on `PATH`, and their
behaviour is steered entirely by environment variables (`FAKE_YTDLP_MODE`,
`FAKE_FFMPEG_BORDER_MODE`, `FAKE_SYSTEMCTL_ENABLED_STATE`, and so on), so
a test declares the world it wants rather than patching anything. Several
fakes also log their invocations to a file the test then asserts against —
that is how "did it call `systemctl restart`, and exactly once" is
checked.

Adding a fake: keep the same shape. Handle only the invocation forms the
project actually uses, and **fail loudly on anything unrecognised** rather
than returning a plausible-looking default, so a test can never quietly
pass against a fake that did not understand the call.

**Scripts expose seams for testability**, all prefixed `PIGEONCAM_`:
`PIGEONCAM_CONFIG` points at a generated config, `PIGEONCAM_DURABLE_DIR`
relocates the durable markers into a temp dir, `PIGEONCAM_NOW_HHMM` /
`PIGEONCAM_NOW_YMD` make time-of-day gates deterministic,
`PIGEONCAM_ROTATE_SETTLE_DELAY` collapses a real 15-second wait, and the
`PIGEONCAM_DOCTOR_*` ones redirect doctor's filesystem probes. Prefer
adding a seam like these over making a test wait for real time to pass.

**`tests/lib/`** holds `assert.sh` (the assertion vocabulary and the
pass/fail tally) and `fixtures.sh`, whose `write_test_config` generates a
complete valid config that scenarios then `sed` into whatever shape they
need. When you add a config key, add it there too or the schema test will
tell you.

**Real tools are used where they matter.** The suite runs real `ffmpeg`
for anything parsing its output, real `systemd-analyze verify` against the
shipped units, and real throwaway scripts sourcing the real library for
the `set -e`/trap behaviours. A parser tested only against a fake that
echoes strings you wrote yourself proves nothing about the real tool —
that mistake was made here, and a genuinely bordered video had to be
generated with real ffmpeg to actually verify the border detector.

**What the suite cannot cover** — anything needing the camera, a real USB
fault, or a real YouTube channel — is listed honestly in
[tests/MANUAL_VERIFICATION.md](../../tests/MANUAL_VERIFICATION.md) rather
than claimed as passing.

---

## Making a change

1. Read the relevant [INCIDENTS.md](INCIDENTS.md) entry if one exists.
   Most surprising-looking code here is load-bearing scar tissue, and the
   comment above it usually says which incident it came from.
2. Write the test first, and **watch it fail** before writing the fix.
3. Change the code. If it touches config, update `config.example.yaml`,
   `tests/lib/fixtures.sh`, and `tests/test_config_schema.sh` together.
4. If it changes anything a user would notice, update
   `docs/TROUBLESHOOTING.md`; `tests/test_docs_jargon.sh` will reject
   internal vocabulary in user-facing files.
5. `tests/run_all.sh` — all of it, green.
6. `git diff --stat SPEC.md` — must be empty.

Commit messages here run long by normal standards, because the *why*
tends to be the part worth keeping. If a change came from a real failure,
say what the failure was.

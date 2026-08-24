# Design spec: a Debian package

Status: **implemented and verified.** `debian/` is in the tree and builds.
The decisions below are settled and marked as such; they now describe
what the package does rather than what it should do. See "What the build
actually proved" at the end for the verification that was run and the two
bugs it caught.

The settled decisions are this spec's calls, not the operator's. Each is
flagged **DECISION** with its reasoning - disagree with any and change it
here first, since the implementation should follow the spec rather than
re-litigate it.

Scope: a `.deb` for our own use and for anyone who wants one, **not** an
official Debian archive upload. Policy is therefore advisory rather than
binding, and several rules below are deliberately bent — each one says so.

## Verdict

The packaging *mechanics* are already done. `make install` honours
`DESTDIR`, `PREFIX`, `UNITDIR` and `CONFDIR`, relocates cleanly (proven by
`tests/test_makefile.sh` installing to a non-stock prefix and checking that
no stock path survives), and writes nothing outside `DESTDIR`. A
`debian/rules` would be four lines calling into it.

What is *not* done is the design decisions the project has so far been
able to avoid, because a `git clone` into `/opt` doesn't force anyone to
answer them. Packaging does. None require architectural change. The two
that wanted a code change first have had it; what is left is genuinely
judgement, not work.

Difficulty: **a weekend, once the decisions are made.** The decisions are
the work, not the packaging.

---

## Already done

Two items below were worth doing on their own merits and have been:

- **The venv moved out of the install tree** to `/var/lib/pigeoncam/venv`
  (`PIGEONCAM_VENV_DIR` in `lib/pigeoncam-common.sh`, `_venv_dir()` in
  `api/rotate_via_api.py`, which derive it identically from the same two
  overrides). A package manager now owns every file under the install
  root and none under the state directory, `make uninstall` is complete,
  and a read-only install root would work.
- **`DOCDIR` is separate from `PREFIX`** in the Makefile, including the
  ordered substitution that makes the units' `Documentation=` URLs follow
  the docs while `ExecStart=` follows the programs.
  `make install PREFIX=/usr/lib/pigeoncam DOCDIR=/usr/share/doc/pigeoncam
  UNITDIR=/lib/systemd/system` now produces the exact tree a package
  wants, and `tests/test_makefile.sh` asserts that shape.

What remains below is the decisions, not the plumbing.

## The four things that are actually in the way

### 1. yt-dlp: the project deliberately does the thing packaging forbids

This is the sharpest conflict and the only one without a clean answer.

The project refuses the distribution's `yt-dlp` on purpose: it tracks
YouTube's frontend closely, a packaged build goes stale, and a stale
yt-dlp does not fail loudly - it silently misparses the page, which is
exactly the "health layer goes blind" failure this project has already
been bitten by. So it installs the upstream binary to `/usr/local/bin` and
runs `yt-dlp -U` as root, daily, via `pigeoncam-ytdlp-update.timer`.

Every part of that is at odds with packaging:

- a `.deb` may not ship into `/usr/local` - that path belongs to the local
  administrator, and dpkg staying out of it is the whole point;
- a package that installs a timer which *mutates a binary outside dpkg's
  control* is close to the definition of what packaging exists to prevent;
- but `Depends: yt-dlp` reintroduces precisely the staleness the design
  rejects. (For scale: the yt-dlp packaged in the distribution used to
  check this was over a year old.)

There is no option that is simultaneously good packaging and good
behaviour. The options, honestly:

| Option | Cost |
|---|---|
| `Depends: yt-dlp` | Correct packaging, known-bad behaviour. Rejected. |
| `Recommends: yt-dlp`, keep self-update, ship the timer **disabled** | Bends policy knowingly; the operator opts in to the self-updating binary exactly as they do today. |
| Split `pigeoncam-ytdlp-update` into its own package | Same bend, more moving parts, clearer blast radius. |
| Drop the external check from the package | Loses a health layer the project considers load-bearing. |

**DECISION: the second option.** Ship `pigeoncam-ytdlp-update.timer`
present but not enabled. `Recommends: yt-dlp` (not `Depends`), so a
default install pulls it while an operator who wants the upstream binary
can decline without fighting the package manager. `README.Debian` states
plainly that enabling that timer means a root timer updating a binary
dpkg does not own, and why the project prefers that to a stale one.

This bends policy knowingly, which the "not an official archive upload"
scope permits. It keeps the deliberate choice visible to the operator
rather than smuggling it past them, which is the part that actually
matters.

### 2. The Python venv used to live inside the install tree - resolved

`api/rotate_via_api.py` used to re-exec itself under
`<install root>/api/venv/bin/python3`. Under a package that would have
been `/usr/lib/pigeoncam/api/venv`: a directory dpkg owns, filled with
files dpkg does not know about, created after install, and left behind by
`apt remove`.

Depending on system packages instead does not work either: the project
pins `google-api-python-client==2.198.0`, and Debian ships the 1.x
series - a major version apart, not a version-skew nuisance. So the venv
has to exist; it just should not be inside the install tree.

**Resolved.** The venv now lives at `/var/lib/pigeoncam/venv`. It is state,
not program code, and that directory already existed and was already
created by the tmpfiles fragment. Both language halves derive the path
from the same two environment overrides
(`PIGEONCAM_VENV_DIR`, else `PIGEONCAM_DURABLE_DIR/venv`, else the
default) so they cannot disagree - a disagreement would surface as Tier 2
silently appearing unavailable rather than as an error.

**Revisited.** This originally said `postinst` should not create the
venv, on the reasoning that doing so needs network access at install
time and "official Debian forbids outright" - which overstated the actual
rule. There is no policy clause that flatly bans it; what actually exists
is that a package needing the network reaches `contrib`, not `main`
(reproducible, offline-buildable, no non-free dependency), and QA tooling
(piuparts, autopkgtest) commonly runs without network and flags packages
that assume otherwise. `ttf-mscorefonts-installer` is the standing
real-world instance of exactly this: its whole purpose is fetching
content it cannot ship, over the network, from `postinst` - accepted into
`contrib` for that reason instead of rejected outright.

Since this package targets neither `main` nor Debian's own QA
infrastructure, that reasoning does not bind it. **DECISION: `postinst`
attempts to create the venv, unconditionally, on every install and
upgrade where it is not already there.** What still matters, independent
of archive politics: this integration is optional and off by default, so
most installs would pay this cost for a feature they will never use, and
a hard failure over it - no network at install time, `python3-venv`
missing - must never fail the package's own configure step, which would
leave the whole package `half-configured` in dpkg's eyes over one
optional tier. So the attempt is best-effort throughout: every step is
timeout-bounded, every failure is caught and reported as a plain warning
rather than propagated, and a half-built venv (interpreter created, but
`pip install` didn't finish) is left in place rather than deleted -
`pigeoncam-doctor.sh`'s `check_youtube_api` already distinguishes "no
venv" from "venv exists but dependencies don't import cleanly" and names
the one command that resumes the second case, which is simpler than
starting over. That distinction is now a shared helper
(`youtube_api_venv_functional`, `lib/pigeoncam-common.sh`) so `postinst`,
`pigeoncam-doctor.sh`, and `pigeoncam-setup.sh`'s own next-steps message
(which now skips the venv-creation step when one is already functional)
cannot disagree about what "ready" means.

### 3. Config ownership: dpkg conffiles vs. what the Makefile already does

`make install` never overwrites an existing `/etc/pigeoncam/config.yaml`.
dpkg has its own machinery for that (conffiles), and the two would fight:
shipping `config.yaml` as a conffile means every upgrade that changes the
shipped defaults prompts the operator about a file they were always
expected to edit heavily.

**DECISION: not a conffile.** `config.yaml` is generated by `postinst`
from `config.example.yaml` only when absent - exactly what `make install`
already does, so behaviour is identical whether the project arrived by
`make` or by `apt`. dpkg therefore never prompts about a file the
operator was always expected to rewrite.

`postinst` creates `/etc/pigeoncam` mode **0750** (it will hold the
stream key and, if used, OAuth credentials). `postrm purge` removes it
only after printing what is being destroyed; `postrm remove` leaves it
entirely.

Note `config.example.yaml` itself installs under `PREFIX`, not `DOCDIR`:
the scripts name it by path in their own output, and those paths derive
from the install root. See the Makefile comment.

### 4. The units must not start on install

`dh_installsystemd`'s default is to enable and start. All six units carry
`[Install]` sections, so all six are enableable - and starting them on
`apt install` would launch ffmpeg against an unconfigured `config.yaml`,
no camera symlink, and no stream key. Six units failing in a loop is a
poor first impression, and `Restart=always` on the stream service makes it
a noisy one.

**DECISION (non-negotiable):** `dh_installsystemd --no-enable
--no-start`. `postinst` points at `pigeoncam-setup.sh` and then
`pigeoncam-doctor.sh`, and says explicitly that nothing has been started.
Unlike the two above this is not a judgement call - the alternative is a
package that breaks the machine it installs on.

---

## The parts that are genuinely easy

- **No build step.** `debian/rules` is `dh $@` plus an override to pass
  `PREFIX`/`UNITDIR` into `make install`.
- **Relocation already works and is tested.** Package paths would be
  `PREFIX=/usr/lib/pigeoncam`, `UNITDIR=/lib/systemd/system`,
  `CONFDIR=/etc/pigeoncam`.
- **Dependencies are available.** `ffmpeg`, `v4l-utils`, `usbutils`,
  `procps`, `jq`, `uhubctl` and `yq` are all packaged. Note `yq` must be
  the jq-wrapper flavour - `Depends: yq` resolves to the right one on
  Debian, and `pigeoncam-doctor.sh` verifies it at runtime anyway.
  `shellcheck` is build/test-only and must not become a runtime dependency.
- **The tmpfiles fragment and udev rule** are ordinary `dh_installsystemd`
  / `dh_install` material. The udev rule must stay a reference copy under
  `/usr/share/doc/pigeoncam/` - it needs the operator's own vendor and
  product IDs before it means anything.
- **Licensing is trivial.** The Unlicense is public domain; nothing here
  links anything, and the Python dependencies are Apache-2.0 and not
  shipped in the package.

---

## Implementation

Everything below is new; nothing outside `debian/` needs to change.

### `debian/control`

```
Source: pigeoncam
Section: video
Priority: optional
Maintainer: <name> <email>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.6.2
Rules-Requires-Root: no

Package: pigeoncam
Architecture: all
Depends: ${misc:Depends}, ffmpeg, v4l-utils, usbutils, procps, jq, yq, systemd
Recommends: yt-dlp, uhubctl
Suggests: python3-venv
Description: unattended 24/7 webcam livestreaming to YouTube Live
 Captures a single fixed USB webcam and streams it continuously to
 YouTube Live, with independent watchdogs for the failure modes an
 unattended multi-week stream actually hits: ffmpeg exiting, ffmpeg
 hanging while still running, a camera that responds but stops
 delivering new frames, and a broadcast YouTube reports as live while
 serving nothing.
 .
 Rotates broadcasts on a schedule to stay under YouTube's ~12 hour
 continuous-archive limit, optionally centred on solar noon, and keeps a
 configurable local archive.
 .
 Nothing is started or enabled on install: run pigeoncam-setup.sh and
 then pigeoncam-doctor.sh first.
```

`Architecture: all` - nothing is compiled. `uhubctl` is only needed for
the USB-reset escalation path, hence `Recommends`. `python3-venv` is
`Suggests` because it is needed only for the optional YouTube API
integration. `yq` **must** resolve to kislyuk/yq; on Debian it does, and
`pigeoncam-doctor.sh` verifies it at runtime regardless.

### `debian/rules`

```make
#!/usr/bin/make -f
export DEB_BUILD_MAINT_OPTIONS = hardening=+all

%:
	dh $@

override_dh_auto_build:
	# nothing to build

override_dh_auto_install:
	$(MAKE) install DESTDIR=$(CURDIR)/debian/pigeoncam \
	    PREFIX=/usr/lib/pigeoncam \
	    DOCDIR=/usr/share/doc/pigeoncam \
	    UNITDIR=/lib/systemd/system \
	    CONFDIR=/etc/pigeoncam

override_dh_installsystemd:
	dh_installsystemd --no-enable --no-start

override_dh_auto_test:
	# the suite needs real ffmpeg/systemd-analyze and network; run it
	# from the source tree with `make check`, not from the package build
```

`make install` creates `/etc/pigeoncam/config.yaml` when absent. In a
package build `DESTDIR` is empty of it, so the file lands in the
`.deb` - which is wrong, since `postinst` owns that. **The `install`
target must therefore be given a way to skip the config, or `rules` must
delete `debian/pigeoncam/etc/pigeoncam/config.yaml` after
`dh_auto_install`.** Prefer the second: no change to the Makefile, one
explicit line in `rules`, and the reason stays visible where it matters.

### `debian/postinst`

Idempotent, and safe under `set -e`:

1. `install -d -m 0750 /etc/pigeoncam`
2. If `/etc/pigeoncam/config.yaml` is absent, copy it from
   `/usr/lib/pigeoncam/config.example.yaml`, mode 0640.
3. `systemd-tmpfiles --create /etc/tmpfiles.d/pigeoncam.conf || true`
   (a container without the machinery should not fail the install).
4. Print, on a fresh install only (`$1 = configure` with no second
   argument):

   ```
   pigeoncam is installed but not started.
     1. sudo pigeoncam-setup.sh     answer the questions
     2. sudo pigeoncam-doctor.sh    fix anything it reports
     3. sudo pigeoncam-ctl.sh enable && sudo pigeoncam-ctl.sh start
   The udev rule needs your camera's IDs first - see
   /usr/share/doc/pigeoncam/udev/99-pigeoncam.rules.example
   ```

### `debian/postrm`

- `remove`: nothing beyond what dpkg does. Config, recordings and the
  venv all stay.
- `purge`: remove `/etc/pigeoncam` and the package's **own state** under
  `/var/lib/pigeoncam`, **printing what is being destroyed first** - the
  stream key, any OAuth credentials, the rotation markers and the venv.
  Never touch `/usr/local/bin/yt-dlp`: the package did not install it.

  **Not `rm -rf /var/lib/pigeoncam`.** This spec originally said to
  delete the whole tree, recordings included, on the reasoning that
  `/var/lib/<pkg>` is the package's own state and policy permits clearing
  it on purge. The policy reading is right; applying it to recordings was
  not. `/var/lib` is where a *program* keeps state, and a package manager
  may clear it - correct for a rotation marker, badly wrong for a season
  of footage. The real defect was upstream of `postrm`: `segment_dir`
  defaulted under `/var/lib/pigeoncam`, so an operator who never read that
  config line had irreplaceable video written into the one directory a
  package is entitled to erase.

  Fixed in both places. `archive.segment_dir` now has **no default** and
  is required whenever `archive.enabled` is true (doctor FAILs, the stream
  service refuses to start, the wizard asks). And `postrm` removes files
  rather than trees, finishing with a plain `rmdir`: if anything else is
  in there - an archive from a config predating the change - the `rmdir`
  fails, the data survives, and the operator is told what was left.

### `debian/pigeoncam.links` (optional but recommended)

Symlink the operator-facing entry points onto `PATH`, so the commands in
every message this project prints are typeable:

```
usr/lib/pigeoncam/bin/pigeoncam-ctl.sh    usr/sbin/pigeoncam-ctl
usr/lib/pigeoncam/bin/pigeoncam-doctor.sh usr/sbin/pigeoncam-doctor
usr/lib/pigeoncam/bin/pigeoncam-setup.sh  usr/sbin/pigeoncam-setup
```

`/usr/sbin` rather than `/usr/bin`: all three need root to be useful.
**If this is done, the scripts' own printed messages should name the
short form**, which is a small follow-up in `lib/pigeoncam-common.sh`'s
message strings and is worth doing in the same change or not at all -
half-done is worse than neither.

### `debian/README.Debian`

Short, and must cover: nothing is started on install; the yt-dlp
decision and what enabling that timer means; where config, state and
recordings live and which survive `remove` versus `purge`; and that
`postinst` attempts the YouTube API integration's venv automatically and
best-effort, with the one command that finishes it by hand if that
attempt didn't work.

### Verifying it

```bash
dpkg-buildpackage -us -uc -b        # build
lintian ../pigeoncam_*.deb          # expect policy complaints; read them
dpkg -c ../pigeoncam_*.deb          # the tree should match `make install`
sudo dpkg -i ../pigeoncam_*.deb     # install
systemctl is-enabled pigeoncam-stream.service   # MUST say disabled
ls -x /var/lib/pigeoncam/venv/bin/python3        # the venv attempt (needs real network)
sudo dpkg -P pigeoncam              # purge
```

The load-bearing check is the `is-enabled` one: it is the difference
between a package that waits to be configured and one that starts
failing the moment it lands. `dpkg -c` output should be diffed against a
`make install DESTDIR=...` staging tree - they should agree except for
the deliberately-removed `config.yaml`.

The venv line needs the install host to actually reach the network - if
it doesn't, `postinst` should still complete (that's the other half of
this to verify: disconnect the network, or block outbound access, and
confirm `dpkg -i` still succeeds with a plain warning rather than
failing).

`lintian` will complain (`/usr/lib` for a non-library, no manpages, the
non-standard doc layout). Read them and decide; do not chase a clean
lintian run, this is not an archive upload.

### Not in scope

Manpages, a `debian/watch` file, multi-distribution builds, and any
attempt to make `lintian` silent.

---

## Loose ends worth noting

- `Documentation=file:///opt/PigeonCamSteward/SPEC.md` in every unit would
  need to follow the docs to `/usr/share/doc/pigeoncam/`. The existing
  `PREFIX` substitution handles the path but not the split between
  program and documentation directories, which a package wants and the
  current Makefile does not model.
- Architecture: `all`. Nothing is compiled.
- The package name should be `pigeoncam`, matching every existing path and
  unit name, rather than `pigeoncamsteward`.

## Order of work

1. ~~Move the venv to `/var/lib/pigeoncam/venv`.~~ Done.
2. ~~Teach the Makefile a `DOCDIR` separate from `PREFIX`.~~ Done.
3. ~~Decide the yt-dlp policy.~~ Decided above.
4. ~~Decide how far config generation goes.~~ Decided: a standalone
   script, specified separately in [setup-script.md](setup-script.md).
   The package only points at it.
5. **`bin/pigeoncam-setup.sh`** - see that spec. Independent of packaging
   and useful on its own, so it can land first and be used by anyone
   installing from git.
6. **`debian/`** - per the Implementation section above.

Steps 5 and 6 are independent; either can be built without the other.
The package is more useful with the setup script than without it, since
`postinst` is specified to point at it.

## What the build actually proved

Both steps are done. The package was built with `dpkg-buildpackage -us
-uc -b`, installed with `dpkg -i`, and its wizard run against the config
its own `postinst` had just created. That end-to-end pass is worth more
than it sounds: it caught two real bugs that every other form of
verification missed, both of the same shape - **something that is only
wrong when `DOCDIR` and `PREFIX` are different directories, which no
other install shape makes true.**

1. **24 operator-facing messages named a document via
   `PIGEONCAM_PROJECT_ROOT`.** The `DOCDIR` commit moved `docs/`,
   `README.md`, `SPEC.md` and the udev example out from under `PREFIX`,
   but the messages that point at them were not moved with them. In the
   source tree and the `/opt` install `DOCDIR == PREFIX`, so all 24 looked
   correct and the whole suite passed; in the package every one of them
   named a file that was not there - at exactly the moment someone is
   reading an error message to fix a broken stream. Fixed by adding
   `PIGEONCAM_DOC_DIR` (lib/pigeoncam-common.sh), detected at runtime so
   the scripts still relocate with no build step. `tests/test_makefile.sh`
   now resolves every `$PIGEONCAM_DOC_DIR`/`$PIGEONCAM_PROJECT_ROOT` path
   the shipped scripts can print against a split install and fails if any
   does not exist.
2. **`dh_compress` gzipped the documentation.** Default debhelper
   behaviour turns `docs/TROUBLESHOOTING.md` into
   `docs/TROUBLESHOOTING.md.gz`, while the scripts print the uncompressed
   name - the same dangling-pointer failure as (1), arriving by a
   completely different route. Fixed with `override_dh_compress:
   dh_compress -X.md`; `changelog` and `README.Debian` keep the
   conventional `.gz`, since nothing points at them by path.

Verified in the built package: `config.yaml` is not shipped and not a
conffile (`/etc/tmpfiles.d/pigeoncam.conf` is the only conffile);
`postinst` creates it at 0640 in a 0750 `/etc/pigeoncam`; no unit is
enabled or started (no `deb-systemd-invoke start` is generated at all,
and a fresh install leaves `/etc/systemd/system/*.wants/` free of
pigeoncam symlinks); and every documented path the scripts print resolves.

One trap for whoever verifies this next: container images routinely carry
`path-exclude=/usr/share/doc/*` in `/etc/dpkg/dpkg.cfg.d/`, so the docs
appear to be missing after `dpkg -i` even though the `.deb` contains
them. Check with `dpkg-deb -c` before believing they were not shipped, or
install with `dpkg -i --path-include='/usr/share/doc/*'`.

**The venv (item 2's revisit) was verified against real network, twice.**
A clean install with a real, working connection produced a genuinely
functional venv - `pip install` pulled and installed
`google-api-python-client==2.198.0` (the exact pinned version) and every
dependency, `youtube_api_venv_functional()` confirmed it, and
`pigeoncam-setup.sh`'s next-steps correctly dropped the now-redundant
venv-creation step. Separately, with the venv's target path structurally
blocked (a plain file sitting where the directory needs to be - the same
deterministic, privilege-independent technique
`tests/test_setup.sh`/`tests/test_doctor.sh` use for their own write-
failure scenarios), `postinst` printed the warning, left every other step
untouched (config.yaml, the tmpfiles fragment, the systemd hooks), and
still exited 0 - confirmed by invoking the installed
`/var/lib/dpkg/info/pigeoncam.postinst` directly with `configure` and an
upgrade-shaped second argument, the same call shape `dpkg` itself uses.

# Design spec: a Debian package

Status: **specified, not implemented**. No decision has been taken to
build this; it exists to answer "how hard would it be, and what would we
have to decide first?"

Scope: a `.deb` for our own use and for anyone who wants one, **not** an
official Debian archive upload. Policy is therefore advisory rather than
binding, and several rules below are deliberately bent — each one says so.

## Verdict

The packaging *mechanics* are already done. `make install` honours
`DESTDIR`, `PREFIX`, `UNITDIR` and `CONFDIR`, relocates cleanly (proven by
`tests/test_makefile.sh` installing to a non-stock prefix and checking that
no stock path survives), and writes nothing outside `DESTDIR`. A
`debian/rules` would be four lines calling into it.

What is *not* done is three design decisions the project has so far been
able to avoid, because a `git clone` into `/opt` doesn't force anyone to
answer them. Packaging does. None require architectural change; two want
a small code change first.

Difficulty: **a weekend, once the decisions are made.** The decisions are
the work, not the packaging.

---

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

**Recommended:** the second. Ship the timer present but not enabled,
document in `README.Debian` that enabling it means a root timer updating a
binary dpkg does not own, and let `pigeoncam-doctor.sh` warn when the
`yt-dlp` on PATH looks like a distribution build. That keeps the deliberate
choice visible rather than smuggling it past the operator.

### 2. The Python venv lives inside the install tree

`api/rotate_via_api.py` re-execs itself under
`<install root>/api/venv/bin/python3`. Under a package that is
`/usr/lib/pigeoncam/api/venv`: a directory dpkg owns, filled with files
dpkg does not know about, created after install, and left behind by
`apt remove`.

Depending on system packages instead does not work: the project pins
`google-api-python-client==2.198.0`, and Debian ships the 1.x series -
a major version apart, not a version-skew nuisance.

**Recommended, and worth doing regardless of packaging:** move the venv out
of the install tree to `/var/lib/pigeoncam/venv`. It is state, not program
code, and `/var/lib/pigeoncam` already exists and is already created by the
tmpfiles fragment. That single change makes `apt purge` clean, makes
`make uninstall` complete, and stops a read-only `/usr` from being a
problem. It touches `_VENV_PYTHON` in `api/rotate_via_api.py` and
`youtube_api_venv_python()` in `lib/pigeoncam-common.sh`, both of which
already have test coverage.

The venv would then be created by the operator (as today) or by `postinst`.
Creating it in `postinst` needs network access at install time, which
official Debian forbids outright; for our purposes it is merely impolite,
and the alternative - the API integration simply not working until the
operator runs one documented command - is arguably better anyway, since
that integration is optional and needs an OAuth flow the operator has to
drive by hand regardless.

### 3. Config ownership: dpkg conffiles vs. what the Makefile already does

`make install` never overwrites an existing `/etc/pigeoncam/config.yaml`.
dpkg has its own machinery for that (conffiles), and the two would fight:
shipping `config.yaml` as a conffile means every upgrade that changes the
shipped defaults prompts the operator about a file they were always
expected to edit heavily.

**Recommended:** do not ship `config.yaml` as a conffile at all. Ship
`config.example.yaml` to `/usr/share/doc/pigeoncam/`, and have `postinst`
create `/etc/pigeoncam` (mode 0750) and copy the example to `config.yaml`
only if absent - which is exactly what the Makefile does today, so
behaviour stays identical whether installed by `make` or by `apt`.
`postrm purge` should remove `/etc/pigeoncam` only after warning that it
holds the stream key and any OAuth credentials.

### 4. The units must not start on install

`dh_installsystemd`'s default is to enable and start. All six units carry
`[Install]` sections, so all six are enableable - and starting them on
`apt install` would launch ffmpeg against an unconfigured `config.yaml`,
no camera symlink, and no stream key. Six units failing in a loop is a
poor first impression, and `Restart=always` on the stream service makes it
a noisy one.

**Required:** `dh_installsystemd --no-enable --no-start`, and `postinst`
should point at `pigeoncam-doctor.sh` as the next step. This is the one
item here that is simply non-negotiable rather than a judgement call.

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

## Loose ends worth noting

- `Documentation=file:///opt/PigeonCamSteward/SPEC.md` in every unit would
  need to follow the docs to `/usr/share/doc/pigeoncam/`. The existing
  `PREFIX` substitution handles the path but not the split between
  program and documentation directories, which a package wants and the
  current Makefile does not model.
- Architecture: `all`. Nothing is compiled.
- The package name should be `pigeoncam`, matching every existing path and
  unit name, rather than `pigeoncamsteward`.

## Suggested order, if this is ever built

1. Move the venv to `/var/lib/pigeoncam/venv`. Useful on its own; makes
   both `apt purge` and `make uninstall` complete.
2. Decide and write down the yt-dlp policy. This is a product decision,
   not a packaging one, and it should be settled in the open.
3. Teach the Makefile a `DOCDIR` separate from `PREFIX`.
4. Then `debian/` is mechanical: `control`, `rules`, `postinst`, `postrm`,
   `install`, `README.Debian`.

Steps 1 and 3 are worth doing whether or not a package is ever built.

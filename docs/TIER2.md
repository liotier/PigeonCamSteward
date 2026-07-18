# Tier 2 setup (FR15)

Tier 2 adds two things on top of Tier 1's default restart-based rotation
(FR14): overlap-free scheduled rotation via the YouTube Data API, and the
last-resort recovery path (FR7e) for a broadcast stuck at "Preparing
stream" that survives plain restarts. See
[SPEC.md §5.4.1](../SPEC.md#541-tier-2-api-call-sequence-reference-implementation-for-apirotate_via_apipy)
for the full call-sequence rationale and
[docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-stuck-broadcast-recovery-recipe-fr15fr7e)
for the manual recipe Tier 2 replaces.

Tier 1 is fully functional without any of this. Do this when you're ready
for either the rotation-precision benefit or the stuck-broadcast recovery
guarantee, or both.

## 1. Google Cloud Console: create an OAuth client

The consent-screen configuration moved under a section renamed **Google
Auth Platform** (formerly "OAuth consent screen") in 2024/2025 - if what
you see doesn't match this exactly, look for the conceptually-equivalent
option; Google reshuffles this UI periodically.

1. Go to [console.cloud.google.com](https://console.cloud.google.com/) and
   create a project (or reuse one) for this.
2. **APIs & Services → Library** → search "YouTube Data API v3" → **Enable**.
3. **APIs & Services → Google Auth Platform** - walk through its tabs:
   - **Branding**: an app name (e.g. "PigeonCamSteward") and your support
     email.
   - **Audience**: user type **External** (personal `@gmail.com` accounts
     don't get an Internal option - that's Workspace-only). Under **Test
     users** on this same tab, add your own Google account. This lets you
     complete auth while the app stays in "Testing" status indefinitely
     for personal use - you do not need to submit it for verification.
   - **Data Access**: **Add or Remove Scopes** → add
     `https://www.googleapis.com/auth/youtube` explicitly here too, even
     though `api/rotate_via_api.py`'s `SCOPES` constant also requests it
     at runtime - belt and suspenders.
   - **Contact Information**: an email for Google's own project
     notifications (same address is fine).
4. Still under **Google Auth Platform**, go to the **Clients** tab →
   **Create Client**:
   - Application type: **Desktop app** (listed under "Native
     Applications").
   - Name it, click **Create**.
   - Download the resulting JSON.
5. Save it wherever `tier2.client_secret_file` in `config.yaml` points
   (default `/etc/pigeoncam/tier2_client_secret.json`), then:
   ```bash
   sudo chmod 600 /etc/pigeoncam/tier2_client_secret.json
   ```

## 2. Set up the venv

Tier 2's dependencies are isolated from system Python (SPEC.md §6a). On
Debian/Ubuntu, the `venv` module is packaged separately from `python3`
(SPEC.md §6a's dependency table already names `python3-venv` for this
reason) - install it first if `python3 -m venv` below fails with
"ensurepip is not available":

```bash
sudo apt install -y python3-venv
cd /opt/PigeonCamSteward
python3 -m venv api/venv
api/venv/bin/pip install -r api/requirements.txt
```

## 3. One-time interactive authorization

**Always invoke it through `api/venv/bin/python3` explicitly, as below -
never `./api/rotate_via_api.py` directly.** Direct execution resolves
`python3` via the shebang/PATH (system Python), which deliberately does
not have Tier 2's dependencies installed (SPEC.md §6a) - you'll hit
`ModuleNotFoundError: No module named 'google'`. The script now catches
this and prints the fix, but it's one less detour to know up front.

```bash
PIGEONCAM_CONFIG=/etc/pigeoncam/config.yaml api/venv/bin/python3 api/rotate_via_api.py --authorize
```

This is interactive and can't run headless (SPEC.md §5.4.1) - it opens a
local HTTP listener on `tier2.oauth_redirect_port` (default 8090) for the
OAuth redirect and prints a consent URL.

- **Local machine with a browser:** it should open automatically; if not,
  copy the printed URL.
- **Headless / SSH:** forward the port before running the command above:
  ```bash
  ssh -L 8090:localhost:8090 you@your-pigeoncam-host
  ```
  then open the printed URL in your *local* browser once it appears.

**Expect a "Google hasn't verified this app" warning screen** - normal for
an app left in Testing status, which is exactly what step 1 set up.
Click **Advanced → Go to `<app name>` (unsafe)** to proceed; it's your own
app, so this is safe, Google just hasn't run it through their (unnecessary
for personal use) verification review.

On success it writes `tier2.token_file` (default
`/etc/pigeoncam/tier2_token.json`, mode 600 automatically) and every
unattended run after this refreshes its own access token from the stored
refresh token - no further interaction needed unless you revoke access in
your Google account or delete the token file.

## 4. Find your persistent stream's id

You need the `liveStreams` resource id for your channel's reusable/
persistent stream key - the same key `youtube.stream_key_file` already
references for Tier 1. Now that step 3 has authorized you:

```bash
api/venv/bin/python3 api/rotate_via_api.py --list-streams
```

Put the id it prints into `config.yaml` as `tier2.persistent_stream_id`.

## 5. Turn it on

```yaml
tier2:
  enabled: true
  persistent_stream_id: "..."   # from step 4
youtube:
  rotation:
    mode: api   # optional - omit to keep Tier 1's restart-based rotation
                # and use Tier 2 *only* for FR7e recovery
```

Then confirm everything's in place:

```bash
sudo PIGEONCAM_CONFIG=/etc/pigeoncam/config.yaml /opt/PigeonCamSteward/bin/pigeoncam-doctor.sh
```

`pigeoncam-doctor.sh`'s Tier 2 check confirms the venv exists and its
dependencies actually import, the client secret and token files exist with
mode 600, and `persistent_stream_id` is set.

**Note:** even with `rotation.mode: api`, FR7e's last-resort recovery uses
Tier 2 whenever it's enabled, regardless of the rotation mode setting -
they're independent switches (`youtube.rotation.mode` picks *how routine
rotation happens*; `tier2.enabled` gates *whether Tier 2 is available at
all*, including for recovery).

## What each mode actually does

| `youtube.rotation.mode` | `tier2.enabled` | Routine rotation | FR7e recovery |
|---|---|---|---|
| `restart` | `false` | Tier 1 stop→gap→start (FR14) | Not available - manual recipe only |
| `restart` | `true` | Tier 1 stop→gap→start (FR14) | Tier 2 API recovery |
| `api` | `true` | Tier 2 explicit transition/insert/bind sequence | Tier 2 API recovery |
| `api` | `false` | **Error** - `pigeoncam-rotate.sh` refuses to half-run this | N/A |

## Troubleshooting

- **`ModuleNotFoundError: No module named 'google'`** - the script was run
  directly (`./api/rotate_via_api.py ...`) instead of through its venv
  (`api/venv/bin/python3 api/rotate_via_api.py ...`); see step 3 above.
  The script prints this same fix itself now, but if you're seeing a raw
  traceback instead, you're running an older checkout - `git pull`.
- **"no venv at api/venv/"** - re-run step 2. `pigeoncam-doctor.sh` checks
  for `api/venv/bin/python3` specifically, not just the script file.
- **"no token file... run --authorize"** - step 3 wasn't completed, or
  `tier2.token_file` in `config.yaml` doesn't match where it was written.
- **Token stops working after a long idle period** - Google can revoke a
  refresh token if it goes unused for an extended period, or if you revoke
  app access under your Google Account's third-party access settings.
  Re-run `--authorize`.
- **A rotation logs `ESCALATION_UNAVAILABLE` instead of attempting
  recovery** - `tier2.enabled` is `false`, or the venv/token/credentials
  check failed silently somewhere; run `pigeoncam-doctor.sh` to pinpoint
  which.
- General API errors during a real rotation: `journalctl -u pigeoncam-rotate`
  (routine rotation) or `journalctl -u pigeoncam-status-check` (FR7e
  recovery) - `rotate_via_api.py`'s own log lines use the same
  `EVENT <LABEL>` convention as the bash scripts (see
  [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md#reading-the-logs-telling-restart-causes-apart)).

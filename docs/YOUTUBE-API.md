# Connecting your YouTube account (optional)

By default this system needs nothing from YouTube but a stream key. Giving
it access to your YouTube account as well buys two things:

- **Cleaner scheduled rotation.** Instead of stopping the stream, waiting,
  and starting it again, it asks YouTube directly to end one broadcast and
  begin the next — no gap, and no reliance on YouTube noticing that the old
  session went away.
- **Automatic recovery from a stuck broadcast.** A broadcast wedged at
  "Preparing stream" can survive any number of plain restarts. This is the
  only mechanism that reliably clears it without you opening a browser.
  Without it, your only option is the
  [manual recipe](TROUBLESHOOTING.md#the-stuck-broadcast-recovery-recipe),
  which needs you to be awake and at a computer.

Everything else works fully without this. Set it up when you want either of
the two benefits above — or, most commonly, when a stuck broadcast has
woken you up once and you'd rather it fixed itself next time.

It takes about fifteen minutes, most of it in Google's console.

> **Upgrading from an older install?** These settings used to live under
> a block called `tier2:`, with `tier2_*.json` credential filenames. They
> are now `youtube_api:` and `youtube_api_*.json`. `pigeoncam-doctor.sh`
> detects the old names and tells you exactly what to change.

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
     users** on this same tab, add your own Google account - **skipping
     this, or authorizing with a different account than the one added
     here, is the most common cause of `Error 403: access_denied` in step
     3** (see Troubleshooting below). Adding yourself as a test user lets
     you complete auth while the app stays in "Testing" status - you do
     not need to submit it for verification for personal use. Testing
     status has a real operational cost, though: **Google hard-expires the
     refresh token 7 days after it's issued while in this status, no
     matter how often it's used** - see "Token expires every ~7 days" in
     Troubleshooting below for the field-confirmed symptom and the fix.
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
5. Save it wherever `youtube_api.client_secret_file` in `config.yaml` points
   (default `/etc/pigeoncam/youtube_api_client_secret.json`), then:
   ```bash
   sudo chmod 600 /etc/pigeoncam/youtube_api_client_secret.json
   ```

## 2. Set up the venv

These dependencies are isolated from system Python. On
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

These dependencies live in `api/venv/`, never system Python (SPEC.md
§6a). Running `./api/rotate_via_api.py` directly, or `python3
api/rotate_via_api.py`, works too now - it re-execs itself under
`api/venv/bin/python3` automatically the moment it notices it isn't
already running under it, so you don't need to remember that venv exists
or type its path. The venv-qualified form below is still what's
documented throughout, since it's the one form guaranteed correct even in
the (very) unlikely case the automatic hand-off itself has a problem:

```bash
PIGEONCAM_CONFIG=/etc/pigeoncam/config.yaml api/venv/bin/python3 api/rotate_via_api.py --authorize
```

Run this as **yourself**, not root - it needs a real browser session, which
root doesn't have (same reason PulseAudio/PipeWire setup needs a real user
too - see docs/TROUBLESHOOTING.md "Real audio mode" if that's ringing a
bell). But `youtube_api.token_file` defaults under `/etc/pigeoncam`, which is
root-owned by design (README's ownership note) - as yourself, you won't
be able to create it there yet. Hand it over first:

```bash
sudo touch /etc/pigeoncam/youtube_api_token.json
sudo chown "$(whoami)" /etc/pigeoncam/youtube_api_token.json
```

Skip this and the script now fails fast with the same fix, before you've
clicked through Google's consent screen - but doing it up front avoids
the round trip.

This is interactive and can't run headless (SPEC.md §5.4.1) - it opens a
local HTTP listener on `youtube_api.oauth_redirect_port` (default 8090) for the
OAuth redirect and prints a consent URL.

- **Local machine with a browser:** it should open automatically; if not,
  copy the printed URL.
- **Headless / SSH:** forward the port before running the command above:
  ```bash
  ssh -L 8090:localhost:8090 you@your-pigeoncam-host
  ```
  then open the printed URL in your *local* browser once it appears.

**If your Google Account manages more than one YouTube channel** (a
personal channel plus a Brand Account channel created for this project is
the common case), the account-chooser screen that opens first lists each
channel as its own selectable entry, not just your Google login email -
pick the exact channel this `config.yaml` is for. Whichever one you pick
here is what every subsequent API call (`--list-streams`, routine
rotation, `--recover`) resolves "my channel" to, permanently, until you
`--authorize` again - regardless of which channel is active in Studio or
anywhere else afterward. Picking the wrong one used to fail silently: no
error at authorize time, just the wrong channel's streams and broadcasts
from then on, surfacing only as a confusing 403/404 the next time a
rotation actually ran - field-caught this way twice now. If
`youtube_api.persistent_stream_id` is already set in `config.yaml` (i.e. this is
a re-authorization, not first-time setup), `--authorize` now checks right
away whether the account you just picked can actually see that stream,
and prints an unmissable warning if not - re-run `--authorize` and pick
the correct entry, no need to revoke anything first. On first-time setup
there's nothing to check yet (that's `--list-streams`, step 4 below) - the
same care picking the right entry still matters there.

**Expect a "Google hasn't verified this app" warning screen** - normal for
an app left in Testing status, which is exactly what step 1 set up.
Click **Advanced → Go to `<app name>` (unsafe)** to proceed; it's your own
app, so this is safe, Google just hasn't run it through their (unnecessary
for personal use) verification review.

On success it writes `youtube_api.token_file` (default
`/etc/pigeoncam/youtube_api_token.json`, mode 600 automatically) and every
unattended run after this refreshes its own access token from the stored
refresh token - no further interaction needed unless you revoke access in
your Google account or delete the token file.

## 4. Find your persistent stream's id

You need the `liveStreams` resource id for your channel's reusable/
persistent stream key - the same key `youtube.stream_key_file` already
references. Now that step 3 has authorized you:

```bash
api/venv/bin/python3 api/rotate_via_api.py --list-streams
```

Put the id it prints into `config.yaml` as `youtube_api.persistent_stream_id`.

## 5. Turn it on

```yaml
youtube_api:
  enabled: true
  persistent_stream_id: "..."   # from step 4
youtube:
  rotation:
    mode: api   # optional - omit to keep the default restart-based
                # rotation and use the API *only* for stuck-broadcast
                # recovery
```

Then confirm everything's in place:

```bash
sudo PIGEONCAM_CONFIG=/etc/pigeoncam/config.yaml /opt/PigeonCamSteward/bin/pigeoncam-doctor.sh
```

`pigeoncam-doctor.sh`'s YouTube API check confirms the venv exists and its
dependencies actually import, the client secret and token files exist with
mode 600, and `persistent_stream_id` is set.

**Note:** even with `rotation.mode: api`, the last-resort recovery path
uses the API whenever it's enabled, regardless of the rotation mode -
they're independent switches. `youtube.rotation.mode` picks *how routine
rotation happens*; `youtube_api.enabled` gates *whether API access exists at
all*, including for recovery.

## What each mode actually does

| `youtube.rotation.mode` | `youtube_api.enabled` | Routine rotation | Last-resort recovery |
|---|---|---|---|
| `restart` | `false` | Stop→gap→start | Not available - manual recipe only |
| `restart` | `true` | Stop→gap→start | Automatic, via the API |
| `api` | `true` | Explicit end-and-begin via the API | Automatic, via the API |
| `api` | `false` | **Error** - `pigeoncam-rotate.sh` refuses to half-run this | N/A |

## Troubleshooting

- **`ModuleNotFoundError: No module named 'google'`** - the script tries
  to re-exec itself under `api/venv/bin/python3` automatically (step 3
  above) before this can even happen, so seeing it at all means either
  that venv doesn't exist yet (re-run step 2), or it exists but its own
  `pip install` didn't fully complete - re-run: `api/venv/bin/pip install
  -r api/requirements.txt`. The error message tells you which of the two
  it is. A raw traceback instead of either message means you're running
  an older checkout - `git pull`.
- **"no venv at api/venv/"** - re-run step 2. `pigeoncam-doctor.sh` checks
  for `api/venv/bin/python3` specifically, not just the script file.
- **Browser shows `Error 403: access_denied` / "has not completed the
  Google verification process... can only be accessed by
  developer-approved testers"** - your Google account isn't on the OAuth
  app's **Test users** list (step 1's Audience tab), or you're
  authorizing with a different account than the one you added there.
  Fix: **Google Cloud Console → APIs & Services → Google Auth Platform →
  Audience → Test users → Add users**, add the exact address you intend
  to authorize with, then re-run the `--authorize` command - no code or
  config change needed. If your browser has multiple Google accounts
  signed in, use an incognito/private window or explicitly choose "use
  another account" so the consent screen doesn't default to the wrong
  one.
- **`--list-streams` (or a rotation) silently acts on the wrong YouTube
  channel** - no error, just the wrong channel's streams/broadcasts. This
  is a different problem than the 403 above: your Google Account managing
  *multiple* YouTube channels, and the account-chooser during
  `--authorize` (step 3) having captured the wrong one - see the note
  under step 3. Fix: no need to revoke anything first - just re-run
  `--authorize` and pick the correct channel's entry in the chooser this
  time; the token file is overwritten cleanly.
- **"no token file... run --authorize"** - step 3 wasn't completed, or
  `youtube_api.token_file` in `config.yaml` doesn't match where it was written.
- **Token expires every ~7 days, even though it's being used constantly** -
  field-confirmed: 8 consecutive scheduled rotations failed with the exact
  same `invalid_grant: Token has been expired or revoked.`, one rotation
  after roughly a week of frequent successful use, and every attempt after
  that failed identically until re-authorized - not a fluke, and not the
  idle-period case below (this token was in active use every ~12h, not
  sitting unused). This is Google's documented behavior for an OAuth
  client left in **Testing** publishing status (Google Auth Platform →
  Audience, step 1 above): refresh tokens hard-expire 7 days after being
  issued regardless of use, and only re-running `--authorize` (which mints
  a new one with a fresh 7-day clock) resets the clock. Immediate fix:
  re-run `--authorize`. To stop this recurring every week: either move the
  app to **Production** publishing status on that same Audience tab
  (removes the 7-day cap - Cloud Console will tell you at that point
  whether your scope needs verification first, which for a single
  personal-use account is often minimal or not required; you'll still see
  the "Google hasn't verified this app" warning from step 1 either way,
  which is harmless), or just set yourself a recurring reminder to
  `--authorize` weekly if you'd rather stay in Testing status. Either way,
  a repeat of this now reaches `notify_command` (if configured) as
  `ROTATION_FAILED` instead of only ever showing up as a `pigeoncam-rotate`
  journal entry nobody happened to be looking at.
- **Token stops working after a long idle period** - Google can also
  revoke a refresh token if it goes unused for an extended period, or if
  you revoke app access under your Google Account's third-party access
  settings. Re-run `--authorize`.
- **A rotation logs `ESCALATION_UNAVAILABLE` instead of attempting
  recovery** - `youtube_api.enabled` is `false`, or the venv/token/credentials
  check failed silently somewhere; run `bin/pigeoncam-doctor.sh` to pinpoint
  which.
- General API errors during a real rotation: `journalctl -u pigeoncam-rotate`
  (routine rotation) or `journalctl -u pigeoncam-status-check` (recovery) -
  `rotate_via_api.py`'s own log lines use the same
  `EVENT <LABEL>` convention as the bash scripts (see
  [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md#reading-the-logs-telling-restart-causes-apart)).

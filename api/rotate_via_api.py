#!/usr/bin/env python3
# SPDX-License-Identifier: Unlicense
"""rotate_via_api.py - Tier 2 (FR15): YouTube Data API broadcast rotation
and FR7e last-resort recovery.

Implements the SPEC.md Section 5.4.1 call sequence: transition the prior
broadcast to `complete`, `insert` + `bind` a new broadcast to the
persistent stream, wait for `streamStatus=active`, transition the new
broadcast to `live`. This replaces the empirically-validated but implicit
manual recipe (kill the encoder -> open a fresh Studio session -> restart
the encoder) with explicit, individually-checkable API calls, so no step
depends on undocumented session/timeout behavior in the Studio UI.

Run via its own venv (SPEC.md SS6a: "Isolate Tier 2's dependencies in a
virtualenv rather than the system Python"), never directly - see
docs/TIER2.md. The bin/pigeoncam-*.sh scripts invoke this through
lib/pigeoncam-common.sh's tier2_run(), which always uses api/venv/bin/python3
explicitly rather than relying on this file's own shebang.

Usage:
    rotate_via_api.py --authorize      one-time interactive OAuth consent
    rotate_via_api.py --list-streams   list your account's liveStreams (to find persistent_stream_id)
    rotate_via_api.py                  normal scheduled rotation (FR14's `api` mode)
    rotate_via_api.py --recover        FR7e last-resort recovery
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time

import yaml
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

SCOPES = ["https://www.googleapis.com/auth/youtube"]
API_SERVICE_NAME = "youtube"
API_VERSION = "v3"
STREAM_UNIT = "pigeoncam-stream.service"
LOG_TAG = "pigeoncam-rotate-api"


# --- logging, matching lib/pigeoncam-common.sh's format so journalctl output
# doesn't jar mid-stream between the bash callers and this script -----------
def _ts() -> str:
    return dt.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def log_info(msg: str) -> None:
    print(f"{_ts()} [{LOG_TAG}] INFO  {msg}", flush=True)


def log_warn(msg: str) -> None:
    print(f"{_ts()} [{LOG_TAG}] WARN  {msg}", file=sys.stderr, flush=True)


def log_error(msg: str) -> None:
    print(f"{_ts()} [{LOG_TAG}] ERROR {msg}", file=sys.stderr, flush=True)


def log_event(label: str, msg: str) -> None:
    print(f"{_ts()} [{LOG_TAG}] EVENT {label} {msg}", flush=True)


# --- config ------------------------------------------------------------
def load_config() -> dict:
    config_path = os.environ.get("PIGEONCAM_CONFIG", "/etc/pigeoncam/config.yaml")
    if not os.path.isfile(config_path):
        log_error(f"config file not found: {config_path}")
        sys.exit(1)
    with open(config_path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data or {}


def cfg(config: dict, dotted_path: str, default=None):
    node = config
    for part in dotted_path.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return default if node is None else node


def require_cfg(config: dict, dotted_path: str) -> str:
    value = cfg(config, dotted_path, "")
    if not value:
        log_error(f"{dotted_path} is not set in config.yaml")
        sys.exit(1)
    return value


# --- persistent state (current broadcast id across rotations/reboots) ----
def load_state(config: dict) -> dict:
    state_file = cfg(config, "tier2.state_file", "/var/lib/pigeoncam/tier2_state.json")
    if not os.path.isfile(state_file):
        return {}
    try:
        with open(state_file, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        log_warn(f"could not read state file {state_file}, treating as empty: {exc}")
        return {}


def save_state(config: dict, state: dict) -> None:
    state_file = cfg(config, "tier2.state_file", "/var/lib/pigeoncam/tier2_state.json")
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = f"{state_file}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, state_file)


# --- credentials ---------------------------------------------------------
def _save_token(token_file: str, creds: Credentials) -> None:
    os.makedirs(os.path.dirname(token_file), exist_ok=True)
    with open(token_file, "w", encoding="utf-8") as f:
        f.write(creds.to_json())
    # Same handling discipline as the stream key file (SPEC.md SS5.4.1):
    # not committed, restrictive permissions.
    os.chmod(token_file, 0o600)


def load_credentials(config: dict) -> Credentials:
    token_file = require_cfg(config, "tier2.token_file")
    if not os.path.isfile(token_file):
        log_error(f"no token file at {token_file} - run: {sys.argv[0]} --authorize")
        sys.exit(1)
    creds = Credentials.from_authorized_user_file(token_file, SCOPES)
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        _save_token(token_file, creds)
    return creds


def do_authorize(config: dict) -> None:
    client_secret_file = require_cfg(config, "tier2.client_secret_file")
    if not os.path.isfile(client_secret_file):
        log_error(
            f"tier2.client_secret_file '{client_secret_file}' not found - "
            "download it from Google Cloud Console first (docs/TIER2.md)"
        )
        sys.exit(1)
    token_file = require_cfg(config, "tier2.token_file")
    port = int(cfg(config, "tier2.oauth_redirect_port", 8090))

    print("Starting the one-time OAuth consent flow.")
    print(f"If this is a headless host, forward the port first: ssh -L {port}:localhost:{port} <this-host>")
    print("then open the printed URL in your local browser once it appears.\n")

    flow = InstalledAppFlow.from_client_secrets_file(client_secret_file, SCOPES)
    creds = flow.run_local_server(port=port)
    _save_token(token_file, creds)
    print(f"\nAuthorization complete. Token stored at {token_file} (mode 600).")


# --- Google API helpers, each with bounded retry on transient errors -----
def _with_retry(description: str, fn, max_attempts: int = 3, backoff_seconds: float = 2.0):
    last_exc = None
    for attempt in range(1, max_attempts + 1):
        try:
            return fn()
        except HttpError as exc:
            status = exc.resp.status if exc.resp is not None else None
            # Client errors (bad request, auth, not found, ...) won't be
            # fixed by retrying; only retry server errors and rate limits.
            if status is not None and 400 <= status < 500 and status != 429:
                raise
            last_exc = exc
            log_warn(f"{description} failed (attempt {attempt}/{max_attempts}, HTTP {status}): {exc}")
            if attempt < max_attempts:
                time.sleep(backoff_seconds * attempt)
    raise last_exc


def transition_broadcast(youtube, broadcast_id: str, status: str) -> dict:
    def _call():
        return (
            youtube.liveBroadcasts()
            .transition(broadcastStatus=status, id=broadcast_id, part="id,status")
            .execute()
        )

    result = _with_retry(f"transition {broadcast_id} -> {status}", _call)
    log_event(f"TRANSITION_{status.upper()}", f"broadcast={broadcast_id}")
    return result


def insert_broadcast(youtube, config: dict) -> str:
    title = cfg(config, "tier2.broadcast_title", "Live")
    description = cfg(config, "tier2.broadcast_description", "") or ""
    privacy = cfg(config, "tier2.privacy_status", "public")
    made_for_kids = cfg(config, "tier2.made_for_kids", None)

    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    status_body = {"privacyStatus": privacy}
    if made_for_kids is not None:
        status_body["selfDeclaredMadeForKids"] = bool(made_for_kids)

    body = {
        "snippet": {
            "title": title,
            "description": description,
            "scheduledStartTime": now,
        },
        "status": status_body,
        "contentDetails": {
            # We drive the live transition explicitly (step 6) rather than
            # relying on enableAutoStart, matching SPEC.md SS5.4.1's numbered
            # sequence: predictable and individually observable, at the
            # cost of one extra explicit call.
            "enableAutoStart": False,
            "enableAutoStop": False,
            "enableDvr": True,
        },
    }

    def _call():
        return youtube.liveBroadcasts().insert(part="snippet,status,contentDetails", body=body).execute()

    result = _with_retry("insert broadcast", _call)
    broadcast_id = result["id"]
    log_event("BROADCAST_INSERTED", f"id={broadcast_id} title={title!r}")
    return broadcast_id


def set_video_category(youtube, video_id: str, category_id: str) -> None:
    # videos.update requires the full snippet sub-object, not a bare
    # categoryId - fetch the current snippet first and merge, rather than
    # risk clearing title/description with a partial body.
    def _get():
        return youtube.videos().list(part="snippet", id=video_id).execute()

    resp = _with_retry("fetch video snippet for category update", _get)
    items = resp.get("items", [])
    if not items:
        log_warn(f"could not fetch snippet for {video_id} to set category; skipping")
        return
    snippet = items[0]["snippet"]
    snippet["categoryId"] = category_id

    def _update():
        return youtube.videos().update(part="snippet", body={"id": video_id, "snippet": snippet}).execute()

    _with_retry("set video category", _update)
    log_event("CATEGORY_SET", f"id={video_id} categoryId={category_id}")


def bind_broadcast(youtube, broadcast_id: str, stream_id: str) -> dict:
    def _call():
        return (
            youtube.liveBroadcasts()
            .bind(id=broadcast_id, streamId=stream_id, part="id,contentDetails")
            .execute()
        )

    result = _with_retry(f"bind {broadcast_id} to stream {stream_id}", _call)
    log_event("BROADCAST_BOUND", f"broadcast={broadcast_id} stream={stream_id}")
    return result


def wait_for_stream_active(youtube, stream_id: str, timeout_seconds: float, interval_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while True:
        def _call():
            return youtube.liveStreams().list(part="status", id=stream_id).execute()

        resp = _with_retry("poll liveStreams status", _call)
        items = resp.get("items", [])
        status = items[0].get("status", {}).get("streamStatus") if items else None
        log_info(f"stream {stream_id} status={status or 'unknown'}")
        if status == "active":
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval_seconds)


def discover_current_broadcast_id(youtube, stream_id: str) -> str | None:
    """Looks up the currently-active broadcast actually bound to our
    persistent stream, via the API rather than local state. Used for
    --recover (FR7e's "ambiguous prior broadcast" - local bookkeeping may
    not be trustworthy in exactly the scenario recovery exists for) and as
    a fallback when local state is simply missing (first run, or state
    was lost)."""

    def _call():
        return (
            youtube.liveBroadcasts()
            .list(part="id,contentDetails,status", broadcastStatus="active", mine=True)
            .execute()
        )

    resp = _with_retry("discover current broadcast", _call)
    for item in resp.get("items", []):
        if item.get("contentDetails", {}).get("boundStreamId") == stream_id:
            return item["id"]
    return None


def list_streams(youtube) -> None:
    resp = youtube.liveStreams().list(part="id,snippet,cdn", mine=True).execute()
    items = resp.get("items", [])
    if not items:
        print("No liveStreams found on this account.")
        return
    for item in items:
        ingest = item.get("cdn", {}).get("ingestionInfo", {}).get("ingestionAddress", "?")
        print(f"{item['id']}\t{item['snippet']['title']}\t(ingest: {ingest})")


def restart_stream() -> None:
    log_event("ROTATION_RESTART", f"restarting {STREAM_UNIT}")
    subprocess.run(["systemctl", "restart", STREAM_UNIT], check=True)


# --- the SS5.4.1 sequence itself ------------------------------------------
def do_rotation(youtube, config: dict, recover: bool = False) -> bool:
    stream_id = require_cfg(config, "tier2.persistent_stream_id")

    state = load_state(config)
    prior_id = state.get("current_broadcast_id")

    if recover or not prior_id:
        discovered = discover_current_broadcast_id(youtube, stream_id)
        if discovered:
            prior_id = discovered

    # Step 1: close the outgoing broadcast explicitly, if we know its id.
    # Best-effort: a broadcast that's already complete/stuck should not
    # block the rest of the sequence.
    if prior_id:
        try:
            transition_broadcast(youtube, prior_id, "complete")
        except HttpError as exc:
            log_warn(f"could not transition prior broadcast {prior_id} to complete, continuing anyway: {exc}")
    else:
        log_info("no prior broadcast id known (first run, or none currently bound) - skipping step 1")

    # Step 2: create the new broadcast.
    new_id = insert_broadcast(youtube, config)

    # Step 2b (optional, best-effort): category, per FR15's parenthetical
    # note that Tier 2 is "the natural place to automate setting the video
    # category". Not part of the core 6-step sequence; never blocks it.
    category_id = cfg(config, "tier2.category_id", "")
    if category_id:
        try:
            set_video_category(youtube, new_id, category_id)
        except HttpError as exc:
            log_warn(f"could not set category on {new_id}, continuing without it: {exc}")

    # Step 3: bind to the existing persistent stream (not a new one).
    bind_broadcast(youtube, new_id, stream_id)

    # Persist immediately after bind succeeds, so a failure in a later step
    # doesn't lose track of which broadcast we just created.
    save_state(config, {"current_broadcast_id": new_id})

    # Step 4: (re)start ffmpeg - only after bind, per SPEC.md SS5.4.1's
    # explicit ordering requirement (it matches a documented precondition
    # on step 6, not a style preference).
    restart_stream()

    # Step 5: poll liveStreams.list for status.streamStatus == active.
    timeout_s = float(cfg(config, "tier2.poll_stream_active_timeout_seconds", 120))
    interval_s = float(cfg(config, "tier2.poll_stream_active_interval_seconds", 5))
    if not wait_for_stream_active(youtube, stream_id, timeout_s, interval_s):
        log_error(
            f"stream {stream_id} did not report streamStatus=active within {timeout_s}s - "
            f"NOT transitioning {new_id} to live; it may need manual attention in Studio"
        )
        return False

    # Step 6: only now transition the new broadcast to live.
    transition_broadcast(youtube, new_id, "live")
    log_info(f"rotation complete: broadcast {new_id} is live")
    return True


def build_youtube_client(config: dict):
    creds = load_credentials(config)
    return build(API_SERVICE_NAME, API_VERSION, credentials=creds, cache_discovery=False)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Tier 2 (FR15): YouTube Data API broadcast rotation / recovery")
    parser.add_argument("--authorize", action="store_true", help="one-time interactive OAuth consent")
    parser.add_argument("--recover", action="store_true", help="FR7e last-resort recovery mode")
    parser.add_argument(
        "--list-streams", action="store_true", help="list this account's liveStreams (to find persistent_stream_id)"
    )
    args = parser.parse_args(argv)

    config = load_config()

    if args.authorize:
        do_authorize(config)
        return 0

    if not cfg(config, "tier2.enabled", False):
        log_error("tier2.enabled is false in config.yaml")
        return 1

    youtube = build_youtube_client(config)

    if args.list_streams:
        list_streams(youtube)
        return 0

    if args.recover:
        log_event("ROTATION_START", "FR7e recovery mode")
    else:
        log_event("ROTATION_START", "Tier 2 API rotation")

    ok = do_rotation(youtube, config, recover=args.recover)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

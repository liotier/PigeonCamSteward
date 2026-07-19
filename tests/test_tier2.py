#!/usr/bin/env python3
# SPDX-License-Identifier: Unlicense
"""Tests for rotate_via_api.py's rotation logic (SPEC.md SS5.4.1), using a
hand-built fake YouTube service object so no real network/API call ever
happens. Run via tests/test_tier2.sh, which provisions a throwaway venv
with this project's actual Tier 2 dependencies if one isn't already
available - these tests import rotate_via_api.py directly, so they need
the same google-api-python-client/google-auth-oauthlib/PyYAML stack it
depends on.
"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "api"))
import rotate_via_api as rva  # noqa: E402


class FakeExecutable:
    """Mimics googleapiclient's chained call: x.liveBroadcasts().transition(...).execute()"""

    def __init__(self, result):
        self._result = result

    def execute(self):
        return self._result


class FakeYouTube:
    """Records every call made against it (and, via the restart_stream
    patch in each test, the ffmpeg restart too) into one ordered list, and
    returns scripted responses. Stands in for what
    googleapiclient.discovery.build() would normally return."""

    def __init__(self):
        self.calls = []
        self.stream_status_sequence = ["ready", "active"]
        self.broadcast_status_sequence = ["testStarting", "testing"]
        self._insert_counter = 0
        self.discover_result = None  # set by tests that want --recover's API lookup to find something

    def liveBroadcasts(self):
        return _FakeBroadcasts(self)

    def liveStreams(self):
        return _FakeStreams(self)

    def videos(self):
        return _FakeVideos(self)


class _FakeBroadcasts:
    def __init__(self, yt):
        self.yt = yt

    def transition(self, broadcastStatus, id, part):  # noqa: A002 (matches googleapiclient's own param name)
        self.yt.calls.append(("transition", id, broadcastStatus))
        return FakeExecutable({"id": id, "status": {"lifeCycleStatus": broadcastStatus}})

    def insert(self, part, body):
        self.yt._insert_counter += 1
        new_id = f"NEWBROADCAST{self.yt._insert_counter}"
        self.yt.calls.append(("insert", new_id, body["snippet"]["title"]))
        return FakeExecutable({"id": new_id})

    def bind(self, id, streamId, part):  # noqa: A002, N803
        self.yt.calls.append(("bind", id, streamId))
        return FakeExecutable({"id": id, "contentDetails": {"boundStreamId": streamId}})

    def list(self, part, broadcastStatus=None, mine=None, id=None):  # noqa: A002
        # Mirrors a real constraint of this endpoint: id, mine, and
        # broadcastStatus are mutually exclusive - combining mine with
        # broadcastStatus fails with a real HTTP 400 "Incompatible
        # parameters" (caught in the field against the actual API; see
        # discover_current_broadcast_id()'s comment). Enforcing it here
        # too so a regression is caught by this test suite, not only by
        # a live API call next time.
        if broadcastStatus is not None and mine is not None:
            raise AssertionError(
                "liveBroadcasts.list() called with both mine and broadcastStatus - "
                "the real API rejects this combination with HTTP 400"
            )
        if id is not None:
            # wait_for_broadcast_status()'s poll: mirrors _FakeStreams.list's
            # sequence-popping pattern, standing in for the transient
            # testStarting -> testing settle observed against the real API.
            status = self.yt.broadcast_status_sequence.pop(0) if self.yt.broadcast_status_sequence else "testing"
            self.yt.calls.append(("broadcast_lifecycle_status", status))
            return FakeExecutable({"items": [{"status": {"lifeCycleStatus": status}}]})
        self.yt.calls.append(("list_broadcasts", broadcastStatus))
        items = [self.yt.discover_result] if self.yt.discover_result else []
        return FakeExecutable({"items": items})


class _FakeStreams:
    def __init__(self, yt):
        self.yt = yt

    def list(self, part, id):  # noqa: A002
        status = self.yt.stream_status_sequence.pop(0) if self.yt.stream_status_sequence else "active"
        self.yt.calls.append(("stream_status", status))
        return FakeExecutable({"items": [{"status": {"streamStatus": status}}]})


class _FakeVideos:
    def __init__(self, yt):
        self.yt = yt

    def list(self, part, id):  # noqa: A002
        self.yt.calls.append(("video_snippet_fetch", id))
        return FakeExecutable({"items": [{"snippet": {"title": "x", "categoryId": "1"}}]})

    def update(self, part, body):
        self.yt.calls.append(("video_update", body["snippet"].get("categoryId")))
        return FakeExecutable({})


def base_config(state_file, **overrides):
    tier2 = {
        "enabled": True,
        "persistent_stream_id": "STREAM123",
        "broadcast_title": "Test Broadcast",
        "broadcast_description": "",
        "privacy_status": "unlisted",
        "category_id": "",
        "made_for_kids": None,
        "poll_stream_active_timeout_seconds": 5,
        "poll_stream_active_interval_seconds": 0.01,
        "state_file": state_file,
    }
    tier2.update(overrides)
    return {"tier2": tier2}


class TestRotationSequence(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.state_file = os.path.join(self.tmpdir, "state.json")
        self.config = base_config(self.state_file)
        self.yt = FakeYouTube()
        patcher = mock.patch("rotate_via_api.restart_stream", side_effect=lambda: self.yt.calls.append(("restart",)))
        self.mock_restart = patcher.start()
        self.addCleanup(patcher.stop)

    def test_first_run_skips_close_step_no_prior_id(self):
        ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)
        kinds = [c[0] for c in self.yt.calls]
        # a bare liveBroadcasts.list discovery happens (no local state), but
        # finds nothing, so no transition-to-complete call follows it
        self.assertNotIn("complete", [c[2] for c in self.yt.calls if c[0] == "transition"])
        self.assertEqual(kinds.count("insert"), 1)
        self.assertEqual(kinds.count("bind"), 1)
        self.mock_restart.assert_called_once()

    def test_full_step_order_with_prior_broadcast(self):
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "PRIOR1"}, f)
        ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)

        kinds = [c[0] for c in self.yt.calls]
        # close prior -> insert -> bind -> restart ffmpeg -> poll stream
        # active -> transition testing -> poll broadcast lifeCycleStatus ->
        # transition live. Two hops beyond SPEC.md SS5.4.1's 6-step prose -
        # added after real API errors on a live channel: created->live
        # directly rejected, "ready" not a valid transition target at all,
        # and testing->live immediately after transition() returns success
        # still rejected until lifeCycleStatus actually settles to
        # "testing" (the transition() call succeeding doesn't mean settled
        # yet - it likely passes through a transient testStarting state).
        self.assertEqual(self.yt.calls[0], ("transition", "PRIOR1", "complete"))
        self.assertEqual(kinds[1], "insert")
        self.assertEqual(kinds[2], "bind")
        self.assertEqual(kinds[3], "restart")
        self.assertEqual(self.yt.calls[-1], ("transition", "NEWBROADCAST1", "live"))
        testing_idx = self.yt.calls.index(("transition", "NEWBROADCAST1", "testing"))
        self.assertIn("stream_status", kinds[4:testing_idx])
        self.assertIn("broadcast_lifecycle_status", kinds[testing_idx:])
        # restart must come strictly after bind and strictly before the
        # final live transition - not just "somewhere in the list"
        self.assertLess(kinds.index("bind"), kinds.index("restart"))
        self.assertLess(kinds.index("restart"), len(kinds) - 1)
        self.assertLess(testing_idx, len(kinds) - 1)

    def test_state_persisted_after_bind_not_before(self):
        rva.do_rotation(self.yt, self.config)
        with open(self.state_file, encoding="utf-8") as f:
            state = json.load(f)
        self.assertTrue(state["current_broadcast_id"].startswith("NEWBROADCAST"))

    def test_stream_never_active_does_not_transition_to_live(self):
        self.yt.stream_status_sequence = ["ready"] * 100
        self.config["tier2"]["poll_stream_active_timeout_seconds"] = 0.05
        self.config["tier2"]["poll_stream_active_interval_seconds"] = 0.01

        ok = rva.do_rotation(self.yt, self.config)

        self.assertFalse(ok)
        # neither the testing nor the live transition for the new broadcast
        # may fire - both come after the stream-active check in the
        # sequence, and it never passes here
        new_broadcast_transitions = [c[2] for c in self.yt.calls if c[0] == "transition" and c[1] == "NEWBROADCAST1"]
        self.assertEqual(
            new_broadcast_transitions, [], "must never transition the new broadcast if streamStatus never became active"
        )
        # step 4 (restart) precedes the poll in the sequence, so it still happens
        self.mock_restart.assert_called_once()

    def test_broadcast_never_settles_into_testing_does_not_transition_to_live(self):
        # Distinct from the stream-active case above: the stream itself
        # goes active normally (default stream_status_sequence), but the
        # broadcast's own lifeCycleStatus never progresses past the
        # transient testStarting state into testing.
        self.yt.broadcast_status_sequence = ["testStarting"] * 100
        self.config["tier2"]["poll_stream_active_timeout_seconds"] = 0.05
        self.config["tier2"]["poll_stream_active_interval_seconds"] = 0.01

        ok = rva.do_rotation(self.yt, self.config)

        self.assertFalse(ok)
        live_transitions = [c for c in self.yt.calls if c[0] == "transition" and c[2] == "live"]
        msg = "must never transition to live if the broadcast never settles into testing"
        self.assertEqual(live_transitions, [], msg)
        testing_transitions = [c for c in self.yt.calls if c[0] == "transition" and c[2] == "testing"]
        self.assertEqual(len(testing_transitions), 1, "the testing transition itself should still have been attempted")

    def test_recover_mode_prefers_api_discovery_over_stale_local_state(self):
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "STALE_STATE_ID"}, f)
        self.yt.discover_result = {"id": "DISCOVERED_ID", "contentDetails": {"boundStreamId": "STREAM123"}}

        rva.do_rotation(self.yt, self.config, recover=True)

        close_calls = [c for c in self.yt.calls if c[0] == "transition" and c[2] == "complete"]
        self.assertEqual(len(close_calls), 1)
        msg = "recover mode must trust the API lookup, not stale local state"
        self.assertEqual(close_calls[0][1], "DISCOVERED_ID", msg)

    def test_normal_mode_falls_back_to_discovery_when_state_missing(self):
        # no state file at all - first run, or state was lost
        self.yt.discover_result = {"id": "DISCOVERED_ID2", "contentDetails": {"boundStreamId": "STREAM123"}}

        rva.do_rotation(self.yt, self.config, recover=False)

        close_calls = [c for c in self.yt.calls if c[0] == "transition" and c[2] == "complete"]
        self.assertEqual(close_calls[0][1], "DISCOVERED_ID2")

    def test_category_failure_does_not_abort_rotation(self):
        self.config["tier2"]["category_id"] = "22"

        # self required: patched onto the class, so it's called as an instance method
        def failing_list(self, part, id):  # noqa: A002
            from googleapiclient.errors import HttpError

            resp = mock.Mock(status=404)
            raise HttpError(resp, b"not found")

        with mock.patch.object(_FakeVideos, "list", failing_list):
            ok = rva.do_rotation(self.yt, self.config)

        self.assertTrue(ok, "a category-setting failure must not abort an otherwise-successful rotation")

    def test_category_set_when_configured(self):
        self.config["tier2"]["category_id"] = "15"
        rva.do_rotation(self.yt, self.config)
        updates = [c for c in self.yt.calls if c[0] == "video_update"]
        self.assertEqual(updates, [("video_update", "15")])

    def test_category_not_touched_when_unconfigured(self):
        rva.do_rotation(self.yt, self.config)
        self.assertNotIn("video_update", [c[0] for c in self.yt.calls])


class TestUnattendedErrorHandling(unittest.TestCase):
    """FR8 labeling discipline applies to the unattended rotation/recovery
    path same as everywhere else - a raw traceback in the journal at 3am is
    exactly the failure mode this project otherwise avoids throughout.
    Caught in review: two paths that could raise straight out of main()
    without ever going through log_error()."""

    def test_dead_refresh_token_exits_cleanly_instead_of_raising(self):
        # Google revokes a refresh token after a long idle period, or on
        # manual third-party-access revocation (docs/TIER2.md
        # Troubleshooting) - expected on a multi-week unattended deployment,
        # not a bug.
        from google.auth.exceptions import RefreshError

        tmpdir = tempfile.mkdtemp()
        token_file = os.path.join(tmpdir, "token.json")
        with open(token_file, "w", encoding="utf-8") as f:
            json.dump({"token": "x"}, f)
        config = {"tier2": {"token_file": token_file}}

        fake_creds = mock.Mock(expired=True, refresh_token="y")
        fake_creds.refresh.side_effect = RefreshError("invalid_grant")

        with mock.patch("rotate_via_api.Credentials.from_authorized_user_file", return_value=fake_creds):
            with self.assertRaises(SystemExit) as cm:
                rva.load_credentials(config)
        self.assertEqual(cm.exception.code, 1, "a dead refresh token must exit(1) cleanly, not propagate RefreshError")

    def test_http_error_during_rotation_is_caught_not_raised(self):
        # e.g. a non-retryable 403 quotaExceeded from insert/bind -
        # _with_retry already exhausted retries on anything retryable by the
        # time this reaches main().
        from googleapiclient.errors import HttpError

        resp = mock.Mock(status=403)
        err = HttpError(resp, b'{"error": "quotaExceeded"}')

        with mock.patch("rotate_via_api.load_config", return_value={"tier2": {"enabled": True}}), mock.patch(
            "rotate_via_api.build_youtube_client", return_value=mock.Mock()
        ), mock.patch("rotate_via_api.do_rotation", side_effect=err):
            rc = rva.main([])

        self.assertEqual(rc, 1, "a non-retryable HttpError during rotation must return 1, not propagate")


class TestConfigHelper(unittest.TestCase):
    def test_cfg_dotted_path(self):
        config = {"a": {"b": {"c": 42}}}
        self.assertEqual(rva.cfg(config, "a.b.c"), 42)
        self.assertIsNone(rva.cfg(config, "a.b.missing"))
        self.assertEqual(rva.cfg(config, "a.b.missing", "fallback"), "fallback")
        self.assertEqual(rva.cfg(config, "a.missing.c", "fallback"), "fallback")

    def test_cfg_false_survives_default(self):
        # same false-vs-missing gotcha as the bash cfg() helper - a
        # configured `false` must not be coerced into the default.
        config = {"tier2": {"enabled": False}}
        self.assertIs(rva.cfg(config, "tier2.enabled", True), False)


if __name__ == "__main__":
    unittest.main()

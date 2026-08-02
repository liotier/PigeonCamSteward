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
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from googleapiclient.errors import HttpError

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
        # Full item list for a bare liveBroadcasts.list(broadcastStatus=...)
        # call. discover_result above can only ever express "exactly one
        # broadcast, and it is bound to our stream", which cannot represent
        # the situation the stray sweep exists for: several broadcasts
        # simultaneously active, only one of them still bound. Set this
        # instead when a test needs that.
        self.active_broadcasts = None
        # broadcast_id -> remaining rejection count for transition() calls -
        # set by tests exercising close_broadcast()'s testing-retry path.
        self.reject_transitions_for = {}

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
        remaining = self.yt.reject_transitions_for.get(id, 0)
        if remaining > 0:
            self.yt.reject_transitions_for[id] = remaining - 1
            self.yt.calls.append(("transition_rejected", id, broadcastStatus))
            resp = mock.Mock(status=403)
            raise HttpError(resp, b'{"error": "Invalid transition"}')
        self.yt.calls.append(("transition", id, broadcastStatus))
        if broadcastStatus == "complete":
            # A completed broadcast is no longer active, so the real API
            # stops listing it under broadcastStatus="active". Modelling
            # that here matters: without it the fake keeps advertising a
            # broadcast we just closed as still live, which fabricates a
            # double-close the real API could never produce.
            if self.yt.active_broadcasts is not None:
                self.yt.active_broadcasts = [b for b in self.yt.active_broadcasts if b.get("id") != id]
            if self.yt.discover_result and self.yt.discover_result.get("id") == id:
                self.yt.discover_result = None
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
        if self.yt.active_broadcasts is not None:
            items = self.yt.active_broadcasts
        else:
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
        # The live transition is the last thing done TO a broadcast. It is
        # no longer the last call overall: the stray sweep runs after it
        # (one liveBroadcasts.list, finding nothing here), deliberately
        # after the replacement is confirmed live rather than before.
        live_idx = self.yt.calls.index(("transition", "NEWBROADCAST1", "live"))
        self.assertNotIn("transition", [c[0] for c in self.yt.calls[live_idx + 1:]])
        testing_idx = self.yt.calls.index(("transition", "NEWBROADCAST1", "testing"))
        self.assertIn("stream_status", kinds[4:testing_idx])
        self.assertIn("broadcast_lifecycle_status", kinds[testing_idx:])
        # restart must come strictly after bind and strictly before the
        # final live transition - not just "somewhere in the list"
        self.assertLess(kinds.index("bind"), kinds.index("restart"))
        self.assertLess(kinds.index("restart"), len(kinds) - 1)
        self.assertLess(testing_idx, len(kinds) - 1)

    def test_prior_broadcast_stuck_in_created_closes_via_testing_retry(self):
        # A prior broadcast left in lifeCycleStatus=created (e.g. an
        # earlier recovery attempt that crashed before reaching live)
        # can't be closed with a direct transition to complete any more
        # than it can jump straight to live - caught in the field, twice,
        # on two separate orphaned broadcasts in one debugging session.
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "PRIOR1"}, f)
        self.yt.reject_transitions_for["PRIOR1"] = 1

        ok = rva.do_rotation(self.yt, self.config)

        self.assertTrue(ok, "the new broadcast's own rotation must succeed regardless of how step 1 goes")
        transition_kinds = ("transition", "transition_rejected")
        prior_calls = [(c[0], c[2]) for c in self.yt.calls if c[0] in transition_kinds and c[1] == "PRIOR1"]
        self.assertEqual(
            prior_calls,
            [("transition_rejected", "complete"), ("transition", "testing"), ("transition", "complete")],
            "a direct close rejection must retry via testing before complete succeeds",
        )

    def test_prior_broadcast_close_failure_is_still_best_effort(self):
        # Even if the testing-retry ALSO fails, closing the prior
        # broadcast must never block the rest of the rotation - same
        # best-effort contract the direct-close path already had.
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "PRIOR1"}, f)
        self.yt.reject_transitions_for["PRIOR1"] = 99

        ok = rva.do_rotation(self.yt, self.config)

        self.assertTrue(ok, "a prior broadcast that can't be closed at all must not block the new broadcast going live")
        kinds = [c[0] for c in self.yt.calls]
        self.assertEqual(kinds.count("insert"), 1)
        live_idx = self.yt.calls.index(("transition", "NEWBROADCAST1", "live"))
        self.assertNotIn("transition", [c[0] for c in self.yt.calls[live_idx + 1:]])

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


class TestStrayBroadcastSweep(unittest.TestCase):
    """The 2026-08-02 production failure: a broadcast that is still `active`
    but no longer BOUND to the persistent stream is invisible to both ways
    rotation finds its predecessor (local state, and --recover's
    boundStreamId-filtered discovery), so nothing ever closes it. It stayed
    live across two consecutive rotations, accumulated all the viewers while
    receiving no data, and won the channel's /live redirect."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.state_file = os.path.join(self.tmpdir, "state.json")
        self.config = base_config(self.state_file)
        self.yt = FakeYouTube()
        patcher = mock.patch("rotate_via_api.restart_stream", side_effect=lambda: self.yt.calls.append(("restart",)))
        patcher.start()
        self.addCleanup(patcher.stop)

    def _completed(self):
        return [c[1] for c in self.yt.calls if c[0] == "transition" and c[2] == "complete"]

    def test_orphan_not_bound_to_our_stream_is_still_closed(self):
        # Exactly the production shape: local state knows PRIOR1 (which it
        # closes fine), while ORPHAN - created by YouTube itself, bound to
        # nothing of ours - is live and completely unknown to our
        # bookkeeping.
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "PRIOR1"}, f)
        self.yt.active_broadcasts = [
            {"id": "ORPHAN", "contentDetails": {"boundStreamId": "SOME_OTHER_STREAM"}},
            {"id": "NEWBROADCAST1", "contentDetails": {"boundStreamId": "STREAM123"}},
        ]
        ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)
        self.assertIn("ORPHAN", self._completed())

    def test_sweep_never_closes_the_broadcast_it_just_made_live(self):
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "PRIOR1"}, f)
        self.yt.active_broadcasts = [
            {"id": "NEWBROADCAST1", "contentDetails": {"boundStreamId": "STREAM123"}},
        ]
        ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)
        self.assertNotIn("NEWBROADCAST1", self._completed())

    def test_sweep_can_be_turned_off(self):
        config = base_config(self.state_file, sweep_stray_broadcasts=False)
        self.yt.active_broadcasts = [
            {"id": "ORPHAN", "contentDetails": {"boundStreamId": "SOME_OTHER_STREAM"}},
        ]
        ok = rva.do_rotation(self.yt, config)
        self.assertTrue(ok)
        self.assertNotIn("ORPHAN", self._completed())

    def test_a_stray_that_refuses_to_close_does_not_fail_the_rotation(self):
        # Field-realistic: the 403 "Invalid transition" seen repeatedly on
        # real orphans. The rotation has already succeeded by this point and
        # must not be reported as failed because cleanup couldn't finish.
        self.yt.active_broadcasts = [
            {"id": "STUBBORN", "contentDetails": {"boundStreamId": "SOME_OTHER_STREAM"}},
        ]
        self.yt.reject_transitions_for = {"STUBBORN": 99}
        ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)

    def test_sweep_listing_failure_does_not_fail_the_rotation(self):
        with open(self.state_file, "w", encoding="utf-8") as f:
            json.dump({"current_broadcast_id": "PRIOR1"}, f)
        real_list = _FakeBroadcasts.list
        state = {"n": 0}

        def flaky_list(self_, part, broadcastStatus=None, mine=None, id=None):  # noqa: A002
            if id is None:
                state["n"] += 1
                if state["n"] >= 1:
                    raise HttpError(mock.Mock(status=500, reason="backendError"), b'{"error": "boom"}')
            return real_list(self_, part, broadcastStatus=broadcastStatus, mine=mine, id=id)

        with mock.patch.object(_FakeBroadcasts, "list", flaky_list):
            with mock.patch.object(rva, "_with_retry", side_effect=lambda desc, fn: fn()):
                ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)

    def test_multiple_orphans_all_get_closed(self):
        self.yt.active_broadcasts = [
            {"id": "ORPHAN_A", "contentDetails": {"boundStreamId": "X"}},
            {"id": "ORPHAN_B", "contentDetails": {"boundStreamId": "Y"}},
            {"id": "NEWBROADCAST1", "contentDetails": {"boundStreamId": "STREAM123"}},
        ]
        ok = rva.do_rotation(self.yt, self.config)
        self.assertTrue(ok)
        self.assertIn("ORPHAN_A", self._completed())
        self.assertIn("ORPHAN_B", self._completed())


class TestUnattendedErrorHandling(unittest.TestCase):
    """FR8 labeling discipline applies to the unattended rotation/recovery
    path same as everywhere else - a raw traceback in the journal at 3am is
    exactly the failure mode this project otherwise avoids throughout.
    Caught in review: two paths that could raise straight out of main()
    without ever going through log_error()."""

    def test_dead_refresh_token_exits_cleanly_instead_of_raising(self):
        # Google revokes a refresh token after a long idle period, or on
        # manual third-party-access revocation (docs/YOUTUBE-API.md
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
        resp = mock.Mock(status=403)
        err = HttpError(resp, b'{"error": "quotaExceeded"}')

        with mock.patch("rotate_via_api.load_config", return_value={"tier2": {"enabled": True}}), mock.patch(
            "rotate_via_api.build_youtube_client", return_value=mock.Mock()
        ), mock.patch("rotate_via_api.do_rotation", side_effect=err):
            rc = rva.main([])

        self.assertEqual(rc, 1, "a non-retryable HttpError during rotation must return 1, not propagate")


class TestWrongAccountDetection(unittest.TestCase):
    """Field-motivated, twice now: authorizing with the wrong Google
    account (a browser with more than one signed in, picking the wrong
    one in the OAuth chooser) produces no error at --authorize time - only
    a confusing 403/404 the next time a rotation actually runs. These
    cover the check added to catch it immediately instead."""

    def test_stream_visible_returns_title(self):
        yt = mock.Mock()
        yt.liveStreams.return_value.list.return_value.execute.return_value = {
            "items": [{"id": "STREAM123", "snippet": {"title": "My Pigeon Stream"}}]
        }
        status, detail = rva._check_stream_visibility(yt, "STREAM123")
        self.assertEqual(status, "visible")
        self.assertEqual(detail, "My Pigeon Stream")

    def test_stream_not_visible_when_no_items(self):
        # The real API's error-free way of saying "this id doesn't exist,
        # or isn't yours" - no exception, just an empty items list. This is
        # the actual shape the wrong-account mistake takes.
        yt = mock.Mock()
        yt.liveStreams.return_value.list.return_value.execute.return_value = {"items": []}
        status, detail = rva._check_stream_visibility(yt, "STREAM123")
        self.assertEqual(status, "not_visible")
        self.assertEqual(detail, "")

    def test_check_failed_on_exception_never_raises(self):
        yt = mock.Mock()
        yt.liveStreams.return_value.list.return_value.execute.side_effect = HttpError(
            mock.Mock(status=403, reason="quotaExceeded"), b'{"error": "quotaExceeded"}'
        )
        status, detail = rva._check_stream_visibility(yt, "STREAM123")
        self.assertEqual(status, "check_failed")
        self.assertIn("quotaExceeded", detail)

    def test_warn_skips_api_call_when_stream_id_not_configured(self):
        # First-time setup: persistent_stream_id isn't chosen until
        # --list-streams, the step after --authorize (docs/YOUTUBE-API.md) -
        # nothing to compare against yet, and no network call should happen.
        config = {"tier2": {}}
        with mock.patch("rotate_via_api.build") as mock_build:
            out = io.StringIO()
            with redirect_stdout(out):
                rva._warn_if_wrong_account(config, mock.Mock())
        mock_build.assert_not_called()
        self.assertIn("isn't set in config.yaml yet", out.getvalue())

    def test_warn_prints_confirmation_when_visible(self):
        config = {"tier2": {"persistent_stream_id": "STREAM123"}}
        with mock.patch("rotate_via_api.build"), mock.patch(
            "rotate_via_api._check_stream_visibility", return_value=("visible", "My Pigeon Stream")
        ):
            out = io.StringIO()
            with redirect_stdout(out):
                rva._warn_if_wrong_account(config, mock.Mock())
        self.assertIn("Confirmed", out.getvalue())
        self.assertIn("My Pigeon Stream", out.getvalue())

    def test_warn_prints_unmissable_warning_when_not_visible(self):
        config = {"tier2": {"persistent_stream_id": "STREAM123"}}
        with mock.patch("rotate_via_api.build"), mock.patch(
            "rotate_via_api._check_stream_visibility", return_value=("not_visible", "")
        ):
            out = io.StringIO()
            with redirect_stdout(out):
                rva._warn_if_wrong_account(config, mock.Mock())
        printed = out.getvalue()
        self.assertIn("WARNING", printed)
        self.assertIn("wrong Google account", printed)
        self.assertIn("STREAM123", printed)

    def test_warn_prints_soft_note_when_check_itself_failed(self):
        # A transient failure in the verification call is not itself
        # evidence of a wrong account - must not use the scary "WARNING"
        # wording reserved for an actually-confirmed mismatch.
        config = {"tier2": {"persistent_stream_id": "STREAM123"}}
        with mock.patch("rotate_via_api.build"), mock.patch(
            "rotate_via_api._check_stream_visibility", return_value=("check_failed", "network unreachable")
        ):
            out = io.StringIO()
            with redirect_stdout(out):
                rva._warn_if_wrong_account(config, mock.Mock())
        printed = out.getvalue()
        self.assertNotIn("WARNING", printed)
        self.assertIn("could not verify", printed)
        self.assertIn("network unreachable", printed)


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

# Development documentation

Everything in this directory is written for someone **changing** the
project. If you are running a camera, you want the user documentation
instead:

| You want to… | Read |
|---|---|
| Set the system up and run it | [README.md](../../README.md) |
| Fix something that's misbehaving | [docs/TROUBLESHOOTING.md](../TROUBLESHOOTING.md) |
| Choose cameras, hubs, cabling | [docs/HARDWARE.md](../HARDWARE.md) |
| Let the system fix a stuck broadcast by itself | [docs/YOUTUBE-API.md](../YOUTUBE-API.md) |

Contents here:

| File | What it is |
|---|---|
| [design/](design/) | Specifications written *before* implementing a change. Each states its own status. |
| [INCIDENTS.md](INCIDENTS.md) | Post-mortems of bugs this project has actually shipped and fixed. Written to stop the same class recurring. |
| This file | The map, plus the vocabulary below. |

The frozen requirements live in [SPEC.md](../../SPEC.md) at the repository
root. It is **not edited** — it is the fixed target the implementation is
measured against, and every change here is checked against it rather than
the other way round.

---

## Vocabulary

The spec uses shorthand that is meaningful to a maintainer and meaningless
to a user. Keeping it out of user-facing text is deliberate, so this table
is the bridge in both directions.

| Spec / internal term | What it means | What users are told instead |
|---|---|---|
| **Tier 1** | Everything that works with no credentials beyond a stream key: capture, watchdog, restart-based rotation, external status check. | Nothing — this is just "the system". |
| **Tier 2** | The optional YouTube Data API integration: API-based rotation, and the only mechanism able to force-resolve a stuck broadcast automatically. Config lives under `youtube_api:`. | "YouTube API access", [docs/YOUTUBE-API.md](../YOUTUBE-API.md) |
| **FR<n>** | A numbered functional requirement in SPEC.md §5. | Nothing — described in plain language. |
| **Acceptance criterion `<n>`** | A numbered check in SPEC.md that the test suite maps onto. | Nothing. |
| **Item `<n><letter>`** (e.g. `3b`) | A finding from the 2026-08-02 architecture review, specified in [design/reliability-items-2-3-5.md](design/reliability-items-2-3-5.md). | Nothing — the *behaviour* is documented, the label isn't. |
| **A1/B2/C3/D1…** | Findings from the earlier review pass, same idea. | Nothing. |

### The `tier2:` → `youtube_api:` rename

The config key used to be `tier2:`, mirroring the spec's vocabulary, with
`tier2_client_secret.json` / `tier2_token.json` / `tier2_state.json`
alongside it. It was renamed to `youtube_api:` (and `youtube_api_*.json`)
because it was the one place internal shorthand was staring a user in the
face every time they edited their config.

There is **no compatibility shim**. A single operator ran the only
deployment and coordinated the config change with the upgrade, so a clean
break was cheaper than a dual-read code path that would have to be
maintained and eventually removed. `pigeoncam-doctor.sh`'s
`check_legacy_config_keys()` detects the old names and prints the exact
migration, which is the whole migration story — delete that check once it
has stopped being useful.

`Tier 1`/`Tier 2` still appear in SPEC.md (frozen) and in maintainer
comments, which is what the table above is for.

---

## Working agreements

These are not style preferences. Each one exists because breaking it cost
real debugging time, usually in production.

1. **SPEC.md is frozen.** `git diff --stat SPEC.md` must be empty in every
   commit.
2. **Every fix ships with a test that fails without it.** Verify that
   directly — revert the fix, watch the test fail, restore it. A test
   written after the fix and never seen to fail proves nothing.
3. **Measure, don't reason, about shell semantics.** Several bugs here came
   from confident but wrong assumptions about `set -e`, `pipefail`, and
   SIGPIPE. If a claim about bash behaviour matters, there is a throwaway
   script that demonstrates it.
4. **`x=$(pipeline)` as a bare assignment under `set -euo pipefail` is a
   known killer.** It has silently killed the watchdog more than once. Guard
   it (`|| return 0`, `if …`) or don't write it. See
   [INCIDENTS.md](INCIDENTS.md).
5. **Never write `main "$@" || …` as a dispatch line.** It disables `set -e`
   inside `main` and everything it calls. `tests/test_err_trap.sh` fails the
   build if it appears. A script needing a deliberate non-zero exit calls
   `exit N` explicitly instead.
6. **User-facing text carries no internal vocabulary.**
   `tests/test_docs_jargon.sh` enforces this mechanically for the terms in
   the table above.
7. **Reconstructing something from context is not the same as reading the
   real source, and must say so plainly** - not just flag the obviously
   secret-shaped fields and imply the rest is safe. A config template
   built without the operator's real file shipped two invented key names
   (silent no-ops - `cfg()` returns its default when a key is absent) and
   several deployment-specific values quietly replaced with generic
   defaults, none of it flagged for review. See
   [INCIDENTS.md](INCIDENTS.md)'s last entry.
   `pigeoncam-doctor.sh`'s `check_unrecognized_config_keys()` is the
   mechanical backstop for the key-name half of this - it can't catch a
   value that's merely wrong-but-real-looking, only a key nothing reads.

## Running the checks

```bash
tests/run_all.sh          # everything; this is the gate
tests/shellcheck.sh       # lint only
tests/test_<area>.sh      # one area
```

The suite deliberately runs real `ffmpeg`, real `systemd-analyze`, and real
throwaway scripts sourcing the real library, rather than mocking them —
most of the bugs worth catching here only appear against the real tools.
Checks that need hardware or a real YouTube channel are listed in
[tests/MANUAL_VERIFICATION.md](../../tests/MANUAL_VERIFICATION.md) and are
not claimed as passing by the automated suite.

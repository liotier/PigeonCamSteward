#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_docs_jargon.sh - user-facing text carries no internal vocabulary.
#
# SPEC.md is the frozen requirements document and speaks in "Tier 1/Tier 2",
# "FR7c", "acceptance criterion 9". That vocabulary is useful to a
# maintainer and meaningless to someone pointing a camera at a nest, so it
# must not leak into the things a user actually reads: the README, the docs
# they're sent to, the config file they edit, or the messages the scripts
# print at them.
#
# Enforced mechanically rather than by review, because de-jargoning is
# exactly the kind of work that silently rots the moment someone adds a
# feature and copies a neighbouring comment.
#
# SPEC.md itself, docs/development/**, and code comments are all deliberately
# exempt - see docs/development/README.md for the vocabulary table that
# translates between the two registers.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_docs_jargon.sh ==="

# The banned patterns. `tier2` as a *config key* or *filename*
# (tier2.enabled, tier2_token.json) is deliberately allowed: renaming it
# would break every deployed config.yaml for a cosmetic gain, so the key
# stays and the prose around it explains itself. What's banned is the
# narrative register - "Tier 2 is...", "Tier 1's default".
JARGON='(Tier ?[12]\b|\bFR[0-9]+[a-z]?\b|\bacceptance criteri|\bcriterion [0-9]|\bitem [0-9][abc]?\b)'

USER_DOCS=(
    "$REPO_ROOT/README.md"
    "$REPO_ROOT/docs/TROUBLESHOOTING.md"
    "$REPO_ROOT/docs/HARDWARE.md"
    "$REPO_ROOT/docs/YOUTUBE-API.md"
    "$REPO_ROOT/config.example.yaml"
)

for f in "${USER_DOCS[@]}"; do
    rel=${f#"$REPO_ROOT/"}
    hits=$(grep -nEo "$JARGON" "$f" 2>/dev/null | sort -u | tr '\n' ' ')
    assert_eq "" "${hits// /}" "$rel carries no internal vocabulary (found: ${hits:-none})"
done

# Runtime messages the operator reads in the journal or on a terminal.
# Code *comments* are maintainer-facing and exempt, so this looks only at
# lines that actually emit output.
EMITTERS='(log_info|log_warn|log_error|log_event|notify_escalation|result |echo )'
while IFS= read -r script; do
    rel=${script#"$REPO_ROOT/"}
    hits=$(grep -hE "$EMITTERS" "$script" | grep -v '^[[:space:]]*#' | grep -Eo "$JARGON" | sort -u | tr '\n' ' ')
    assert_eq "" "${hits// /}" "$rel prints no internal vocabulary at the user (found: ${hits:-none})"
done < <(find "$REPO_ROOT/bin" "$REPO_ROOT/lib" -name '*.sh' -type f | sort)

# The other half of the contract: the vocabulary has to be written down
# *somewhere*, or removing it from user docs just loses the information.
DEV_README="$REPO_ROOT/docs/development/README.md"
assert_file_exists "$DEV_README" "docs/development/README.md exists (the dev-facing entry point)"
dev=$(cat "$DEV_README" 2>/dev/null)
for term in "Tier 1" "Tier 2" "FR<n>"; do
    assert_contains "$dev" "$term" "the development glossary still defines '$term' for maintainers"
done
assert_contains "$dev" "docs/YOUTUBE-API.md" "the glossary points Tier 2 at its user-facing name"

test_summary_and_exit

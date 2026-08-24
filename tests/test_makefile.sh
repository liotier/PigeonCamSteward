#!/usr/bin/env bash
# SPDX-License-Identifier: Unlicense
#
# test_makefile.sh - `make install` puts the tree where it says it does,
# and rewrites the one absolute path that is baked into the shipped files.
#
# The substitution is the part worth testing. Every script derives its own
# root at runtime (PIGEONCAM_PROJECT_ROOT), so the scripts relocate for
# free - but the systemd units carry a literal /opt/PigeonCamSteward in
# ExecStart= and Documentation=, and a unit pointing at a path that does
# not exist fails at start time with a message that says nothing about the
# real cause.
#
# Everything here installs into a DESTDIR under a temp dir, so the suite
# never touches the system it runs on. That is also exactly the invocation
# a package build would use.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
# shellcheck source=tests/lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"

echo "=== test_makefile.sh ==="

if ! command -v make >/dev/null 2>&1; then
    echo "  skip - make not installed"
    test_summary_and_exit
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
run_make() { make -C "$REPO_ROOT" "$@" >"$WORK/make.log" 2>&1; }

# --- install at the stock prefix -----------------------------------------
run_make install DESTDIR="$STAGE"
assert_eq "0" "$?" "make install succeeds"

for f in opt/PigeonCamSteward/bin/pigeoncam-doctor.sh \
         opt/PigeonCamSteward/lib/pigeoncam-common.sh \
         opt/PigeonCamSteward/api/rotate_via_api.py \
         opt/PigeonCamSteward/config.example.yaml \
         opt/PigeonCamSteward/SPEC.md \
         etc/systemd/system/pigeoncam-stream.service \
         etc/systemd/system/pigeoncam-rotate.timer \
         etc/tmpfiles.d/pigeoncam.conf; do
    assert_true "installed: $f" [ -f "$STAGE/$f" ]
done

assert_true "scripts land executable" [ -x "$STAGE/opt/PigeonCamSteward/bin/pigeoncam-doctor.sh" ]

# The udev rule needs the operator's own vendor/product IDs, so it ships as
# a reference copy and is never dropped into /etc/udev/rules.d by install.
assert_true "the udev rule is NOT auto-installed into /etc" \
    [ ! -e "$STAGE/etc/udev/rules.d/99-pigeoncam.rules" ]
assert_true "the udev rule ships as a reference copy instead" \
    [ -f "$STAGE/opt/PigeonCamSteward/udev/99-pigeoncam.rules.example" ]

# --- the point of the exercise: a non-stock prefix ------------------------
STAGE2="$WORK/stage2"
ALT_PREFIX=/usr/local/lib/pigeoncam
run_make install DESTDIR="$STAGE2" PREFIX="$ALT_PREFIX"
assert_eq "0" "$?" "make install succeeds at a non-stock prefix"

units_at_alt=$(grep -h "^ExecStart=" "$STAGE2/etc/systemd/system/"*.service | grep -c "$ALT_PREFIX")
units_total=$(grep -hc "^ExecStart=" "$STAGE2/etc/systemd/system/"*.service | awk '{s+=$1} END{print s}')
assert_eq "$units_total" "$units_at_alt" "every ExecStart= points at the chosen prefix"

stale=$(grep -rl "/opt/PigeonCamSteward" "$STAGE2/etc/" 2>/dev/null | wc -l)
assert_eq "0" "$stale" "no stock path survives anywhere in the installed units"

assert_true "the relocated scripts actually run" \
    bash -c "'$STAGE2$ALT_PREFIX/bin/pigeoncam-doctor.sh' --help >/dev/null 2>&1"

# --- DOCDIR: a package wants docs split away from the programs, and the
#     units' Documentation= URLs have to follow the docs while every other
#     path follows the programs. Two substitutions in one file, so worth
#     asserting both land rather than trusting the ordering. -------------
STAGE_PKG="$WORK/stage-pkg"
PKG_PREFIX=/usr/lib/pigeoncam
PKG_DOCDIR=/usr/share/doc/pigeoncam
run_make install DESTDIR="$STAGE_PKG" PREFIX="$PKG_PREFIX" DOCDIR="$PKG_DOCDIR" \
    UNITDIR=/lib/systemd/system
assert_eq "0" "$?" "make install succeeds with docs split from programs"

assert_true "programs land under PREFIX" \
    [ -x "$STAGE_PKG$PKG_PREFIX/bin/pigeoncam-doctor.sh" ]
assert_true "docs land under DOCDIR" [ -f "$STAGE_PKG$PKG_DOCDIR/SPEC.md" ]
assert_true "the docs tree follows DOCDIR too" [ -d "$STAGE_PKG$PKG_DOCDIR/docs" ]
assert_true "the udev reference copy follows DOCDIR" \
    [ -f "$STAGE_PKG$PKG_DOCDIR/udev/99-pigeoncam.rules.example" ]
assert_true "no docs are left behind under PREFIX" [ ! -e "$STAGE_PKG$PKG_PREFIX/SPEC.md" ]
# config.example.yaml is the deliberate exception: the scripts name it by
# path in their own messages, and those paths derive from the install root.
assert_true "config.example.yaml stays with the programs" \
    [ -f "$STAGE_PKG$PKG_PREFIX/config.example.yaml" ]

assert_contains "$(grep -h '^Documentation=' "$STAGE_PKG/lib/systemd/system/pigeoncam-stream.service")" \
    "$PKG_DOCDIR" "Documentation= in the units follows DOCDIR"
assert_contains "$(grep -h '^ExecStart=' "$STAGE_PKG/lib/systemd/system/pigeoncam-stream.service")" \
    "$PKG_PREFIX" "ExecStart= in the same unit still follows PREFIX"
# Scoped to the units, not the whole tree: the docs legitimately name
# /opt/PigeonCamSteward as the documented default install path, and two
# source files mention it in comments explaining why nothing hardcodes
# it. Those are prose about a path, not a path being used.
assert_eq "0" "$(grep -rl '/opt/PigeonCamSteward' "$STAGE_PKG/lib/systemd/system" 2>/dev/null | wc -l)" \
    "no stock path survives in the units of a package-shaped install"

# --- every path the scripts PRINT has to exist in the tree they print it
#     from. This is the split's real hazard, and it was live: the DOCDIR
#     commit moved docs/, README.md, SPEC.md and the udev example out from
#     under PREFIX, but 24 operator-facing messages across six scripts
#     still named them via PIGEONCAM_PROJECT_ROOT. In the source tree and
#     the /opt install DOCDIR == PREFIX, so every one of them looked
#     correct; only a package-shaped install pulls them apart. Checked
#     statically against the staged tree rather than by running each
#     script, since most of these messages only fire on a failure that
#     can't be provoked here (no camera, no PipeWire session, no units).
missing_docpaths=""
for f in "$STAGE_PKG$PKG_PREFIX/bin/"*.sh "$STAGE_PKG$PKG_PREFIX/tools/"*.sh; do
    [ -f "$f" ] || continue
    # Both roots at once: a doc named via PROJECT_ROOT is exactly the bug,
    # and a program named via DOC_DIR would be the mirror image of it.
    # Trailing '.', ',' and '/' are sentence punctuation the path ran into
    # ("... see .../docs/TROUBLESHOOTING.md."), never part of a filename -
    # strip them, or the check reports a file that is really there.
    refs=$(grep -oE '\$PIGEONCAM_(DOC_DIR|PROJECT_ROOT)/[A-Za-z0-9_./-]+' "$f" \
        | sed 's#[./,]*$##' | sort -u)
    for ref in $refs; do
        case "$ref" in
            '$PIGEONCAM_DOC_DIR/'*)      real="$STAGE_PKG$PKG_DOCDIR/${ref#\$PIGEONCAM_DOC_DIR/}" ;;
            '$PIGEONCAM_PROJECT_ROOT/'*) real="$STAGE_PKG$PKG_PREFIX/${ref#\$PIGEONCAM_PROJECT_ROOT/}" ;;
            *) continue ;;
        esac
        [ -e "$real" ] || missing_docpaths="$missing_docpaths $(basename "$f"):$ref"
    done
done
assert_eq "" "$missing_docpaths" \
    "every \$PIGEONCAM_DOC_DIR/\$PIGEONCAM_PROJECT_ROOT path the scripts print exists in a split install"

# The detection itself. Only the two deterministic branches are asserted
# here: the third (falling back to /usr/share/doc/pigeoncam) depends on
# whether the host running the suite happens to have the package
# installed, so asserting it either way would make this test pass or fail
# for reasons that have nothing to do with the code. That branch is
# exercised by installing the real .deb, which is in the packaging spec's
# verification sequence.
detected_same=$(PIGEONCAM_DOC_DIR="" bash -c \
    "source '$STAGE/opt/PigeonCamSteward/lib/pigeoncam-common.sh' >/dev/null 2>&1; printf '%s' \"\$PIGEONCAM_DOC_DIR\"")
assert_eq "$STAGE/opt/PigeonCamSteward" "$detected_same" \
    "docs alongside the programs (the /opt install): DOC_DIR is the install root"
detected_env=$(PIGEONCAM_DOC_DIR="$STAGE_PKG$PKG_DOCDIR" bash -c \
    "source '$STAGE_PKG$PKG_PREFIX/lib/pigeoncam-common.sh' >/dev/null 2>&1; printf '%s' \"\$PIGEONCAM_DOC_DIR\"")
assert_eq "$STAGE_PKG$PKG_DOCDIR" "$detected_env" \
    "an explicit PIGEONCAM_DOC_DIR always wins, whatever the layout"

# --- an existing config is never overwritten -----------------------------
printf '# a real config, in use\n' > "$STAGE/etc/pigeoncam/config.yaml"
run_make install DESTDIR="$STAGE"
assert_contains "$(cat "$STAGE/etc/pigeoncam/config.yaml")" "a real config, in use" \
    "reinstalling never clobbers an existing config.yaml"
assert_contains "$(cat "$WORK/make.log")" "left untouched" \
    "and says so rather than doing it silently"

# --- uninstall removes the program, keeps the operator's data ------------
run_make uninstall DESTDIR="$STAGE"
assert_eq "0" "$?" "make uninstall succeeds"
assert_true "the program tree is gone" [ ! -d "$STAGE/opt/PigeonCamSteward" ]
assert_true "the units are gone" [ ! -f "$STAGE/etc/systemd/system/pigeoncam-stream.service" ]
assert_true "the tmpfiles fragment is gone" [ ! -f "$STAGE/etc/tmpfiles.d/pigeoncam.conf" ]
assert_true "config and credentials are deliberately kept" [ -f "$STAGE/etc/pigeoncam/config.yaml" ]

# --- install writes only into DESTDIR, never into the source tree --------
# There is no build step, so a stray file appearing under the checkout
# would mean a target wrote somewhere it shouldn't. Compared as a file
# listing rather than via git status, which cannot tell a build artifact
# from the uncommitted work a developer normally has while running this.
before="$WORK/tree-before.txt"; after="$WORK/tree-after.txt"
( cd "$REPO_ROOT" && find . -path ./.git -prune -o -print | sort ) > "$before"
run_make install DESTDIR="$WORK/stage3"
( cd "$REPO_ROOT" && find . -path ./.git -prune -o -print | sort ) > "$after"
assert_eq "" "$(comm -13 "$before" "$after")" "make install creates nothing inside the source tree"

test_summary_and_exit

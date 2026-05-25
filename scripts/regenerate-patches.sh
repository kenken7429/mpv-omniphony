#!/usr/bin/env bash
# Regenerate patches/ from the mpv fork's `orender` branch.
#
# Run this in your mpv fork checkout after committing integration changes on the
# `orender` branch (branched off the pinned upstream tag/`master`).
#
# Usage:
#   scripts/regenerate-patches.sh /path/to/mpv-fork [BASE_REF]
#
# BASE_REF defaults to `master` (the upstream mirror branch). See the top-level
# README for the fork branching workflow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# BASE_REF must match the tag apply-patches.sh checks out (branch `orender` off
# the pinned tag, generate patches relative to it).
FORK="${1:?usage: regenerate-patches.sh /path/to/mpv-fork [BASE_REF]}"
BASE_REF="${2:-v0.41.0}"

if [ ! -d "$FORK/.git" ]; then
    echo "!! $FORK is not a git repo" >&2
    exit 1
fi

echo ">> generating patches from ${BASE_REF}..orender in $FORK"
rm -f "$REPO_ROOT"/patches/*.patch
git -C "$FORK" format-patch "${BASE_REF}..orender" \
    --no-numbered-files --zero-commit --no-signature \
    -o "$REPO_ROOT/patches"

echo ">> wrote:"
ls -1 "$REPO_ROOT"/patches/*.patch

echo ">> reminder: keep src/ad_orender.c in sync with the fork's copy."
echo "   cp \"$FORK/audio/decode/ad_orender.c\" \"$REPO_ROOT/src/ad_orender.c\""

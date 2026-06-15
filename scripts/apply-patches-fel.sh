#!/usr/bin/env bash
# Produce a buildable mpv tree carrying the orender patches PLUS the Dolby Vision
# FEL patch. FEL pairs with the master-tracking flow only (the FEL patch is
# generated against mpv master; the pinned v0.41.0 tree is intentionally not
# supported here).
#
# Steps:
#   1. scripts/apply-patches-master.sh   -> build/mpv-master-<sha> (orender)
#   2. apply patches-fel/*.patch on top  (dv-fel)
#
# Usage: scripts/apply-patches-fel.sh
# Prints the resolved mpv SHA on the last line as: MPV_FEL_SHA=<sha>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$REPO_ROOT/build"

echo ">> applying orender (master) patches"
bash "$REPO_ROOT/scripts/apply-patches-master.sh"

# apply-patches-master.sh names the tree build/mpv-master-<short-sha> from the
# refreshed clone's HEAD; re-derive the same path.
SHORT_SHA="$(git -C "$WORKDIR/mpv-master-clone" rev-parse --short HEAD)"
SRC="$WORKDIR/mpv-master-${SHORT_SHA}"
[ -d "$SRC" ] || { echo "!! expected tree $SRC not found" >&2; exit 1; }

shopt -s nullglob
patches=("$REPO_ROOT"/patches-fel/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "!! no patches in patches-fel/ — vendor the FEL mpv patch first" >&2
    exit 1
fi

echo ">> applying ${#patches[@]} FEL patch(es) onto $SRC"
for p in "${patches[@]}"; do
    echo "   - $(basename "$p")"
    git -C "$SRC" apply --3way --whitespace=nowarn "$p"
done

echo ">> done. Build (with FEL deps on PKG_CONFIG_PATH) with:"
echo "   cd $SRC && meson setup _b -Dorender=enabled && meson compile -C _b"
echo "MPV_FEL_SHA=${SHORT_SHA}"

#!/usr/bin/env bash
# Clone mpv at the pinned tag, drop in ad_orender.c, and apply the patches.
# Produces a buildable mpv tree at ./build/mpv-<tag>.
#
# Usage: scripts/apply-patches.sh [MPV_TAG]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MPV_TAG="${1:-${MPV_TAG:-v0.40.0}}"   # pin; adjust to a real released tag
MPV_URL="https://github.com/mpv-player/mpv.git"
WORKDIR="$REPO_ROOT/build"
SRC="$WORKDIR/mpv-${MPV_TAG}"

mkdir -p "$WORKDIR"

if [ ! -d "$SRC/.git" ]; then
    echo ">> cloning mpv $MPV_TAG"
    git clone --depth 1 --branch "$MPV_TAG" "$MPV_URL" "$SRC"
else
    echo ">> reusing existing clone at $SRC"
    git -C "$SRC" reset --hard "tags/$MPV_TAG"
    git -C "$SRC" clean -fdx
fi

echo ">> copying ad_orender.c into the tree"
cp "$REPO_ROOT/src/ad_orender.c" "$SRC/audio/decode/ad_orender.c"

shopt -s nullglob
patches=("$REPO_ROOT"/patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "!! no patches in patches/ — generate them first (regenerate-patches.sh)"
    echo "   the tree has ad_orender.c but is NOT wired into the build yet."
    exit 1
fi

echo ">> applying ${#patches[@]} patch(es)"
for p in "${patches[@]}"; do
    echo "   - $(basename "$p")"
    git -C "$SRC" apply --3way "$p"
done

echo ">> done. Build with:"
echo "   cd $SRC && meson setup build -Dorender=enabled && meson compile -C build"

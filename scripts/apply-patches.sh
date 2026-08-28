#!/usr/bin/env bash
# Clone mpv at the pinned tag and apply the patches (patch 0001 adds
# ad_orender.c; 0002/0003 wire it into the decoder list + build).
# Produces a buildable mpv tree at ./build/mpv-<tag>.
#
# Usage: scripts/apply-patches.sh [MPV_TAG]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MPV_TAG="${1:-${MPV_TAG:-v0.41.0}}"   # pinned mpv release tag
MPV_URL="https://github.com/mpv-player/mpv.git"
WORKDIR="$REPO_ROOT/build"
SRC="$WORKDIR/mpv-${MPV_TAG}"

mkdir -p "$WORKDIR"

if [ ! -d "$SRC/.git" ]; then
    echo ">> cloning mpv $MPV_TAG"
    # Full clone (not --depth 1) so 3-way merge has the necessary blobs
    git clone --branch "$MPV_TAG" "$MPV_URL" "$SRC"
else
    echo ">> reusing existing clone at $SRC"
    git -C "$SRC" reset --hard "$MPV_TAG"
    git -C "$SRC" clean -fdx
fi

shopt -s nullglob
patches=("$REPO_ROOT"/patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "!! no patches in patches/ — generate them first (regenerate-patches.sh)"
    exit 1
fi

echo ">> applying ${#patches[@]} patch(es)"
for p in "${patches[@]}"; do
    echo "   - $(basename "$p")"
    # Try 3-way merge first, then fallback to fuzz matching for master compatibility
    git -C "$SRC" apply --3way "$p" || {
        echo "   ! 3-way failed, trying fuzz match..."
        patch -d "$SRC" -p1 --fuzz=3 < "$p"
    }
done

echo ">> done. Build with:"
echo "   cd $SRC && meson setup build -Dorender=enabled && meson compile -C build"

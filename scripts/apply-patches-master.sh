#!/usr/bin/env bash
# Clone mpv master and check out a PINNED commit, then apply patches-master/.
# Produces a buildable tree at ./build/mpv-master-<short-sha>.
#
# Pinned instead of tracking master HEAD: upstream mpv keeps moving and the orender
# patch series (0001-0028) drifts on every master change (e.g. the 2026-09 ad_dsd
# merge broke f_decoder_wrapper.{c,h}). Pin to a commit whose baseline the patches
# are known to apply cleanly against, for a reproducible build.
#
# Usage: scripts/apply-patches-master.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MPV_URL="https://github.com/mpv-player/mpv.git"
MPV_PIN="${MPV_PIN:-e8673660ab}"   # mpv master baseline the patch series targets
WORKDIR="$REPO_ROOT/build"
CLONE_DIR="$WORKDIR/mpv-master-clone"

mkdir -p "$WORKDIR"

if [ ! -d "$CLONE_DIR/.git" ]; then
    echo ">> cloning mpv master (full history, --3way needs blobs)"
    git clone --branch master "$MPV_URL" "$CLONE_DIR"
else
    echo ">> refreshing existing clone at $CLONE_DIR"
    git -C "$CLONE_DIR" fetch origin master
fi
echo ">> checking out pinned mpv master $MPV_PIN"
git -C "$CLONE_DIR" checkout "$MPV_PIN"
git -C "$CLONE_DIR" clean -fdx

SHORT_SHA="$(git -C "$CLONE_DIR" rev-parse --short HEAD)"
SRC="$WORKDIR/mpv-master-${SHORT_SHA}"

if [ -d "$SRC" ]; then
    echo ">> removing stale $SRC"
    rm -rf "$SRC"
fi

echo ">> snapshotting clone to $SRC (HEAD=$SHORT_SHA)"
cp -a "$CLONE_DIR" "$SRC"
# cp -a copies the index file with the source's stat data, but the working-tree
# files have new inode/mtime. Refresh the snapshot's index so `git apply --3way`
# sees a clean tree (without this, --3way rejects every modified file).
git -C "$SRC" update-index --refresh >/dev/null 2>&1 || true

shopt -s nullglob
patches=("$REPO_ROOT"/patches-master/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "!! no patches in patches-master/ — generate them first"
    echo "   scripts/regenerate-patches-master.sh /path/to/mpv-fork"
    exit 1
fi

echo ">> applying ${#patches[@]} patch(es)"
for p in "${patches[@]}"; do
    echo "   - $(basename "$p")"
    git -C "$SRC" apply --3way "$p"
done

echo ">> done. Build with:"
echo "   cd $SRC && meson setup build -Dorender=enabled && meson compile -C build"

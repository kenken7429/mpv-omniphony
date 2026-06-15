#!/usr/bin/env bash
# Build the Dolby Vision FEL dependency stack into an isolated $PREFIX, to be
# linked afterwards by the normal mpv build (export PKG_CONFIG_PATH / PATH).
#
# FEL needs three libs that no released distro/package ships yet:
#   libdovi      RPU parsing for the enhancement layer (pkg-config: dovi)
#   libplacebo   dv-fel branch, reconstructs the FEL (needs PL_API_VER >= 367)
#   ffmpeg       + vendored dovi_split BSF (deps-fel/ffmpeg/*.patch)
#
# This is NOT the mpv build — it is only the FEL delta on the dependency side.
# Refs/branches come from deps-fel/pins-fel.env (policy: follow dv-fel HEAD).
#
# Usage:
#   PREFIX=/path/to/prefix scripts/build-fel-deps.sh            # native (Linux)
#   PREFIX=/path CROSS_FILE=cross.ini scripts/build-fel-deps.sh --cross   # MinGW
#
# Env:
#   PREFIX        install prefix (default: $PWD/fel-prefix)
#   WORK          checkout/build scratch dir (default: $PWD/fel-work)
#   JOBS          parallelism (default: nproc)
#   CROSS_FILE    meson cross-file (required with --cross)
#   CROSS_PREFIX  toolchain prefix for --cross (default: x86_64-w64-mingw32-)
#   RUST_TARGET   cargo target for --cross (default: x86_64-pc-windows-gnu)
#   SKIP_LIBDOVI  set to 1 to reuse a libdovi already on PKG_CONFIG_PATH
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deps-fel/pins-fel.env
source "$REPO_ROOT/deps-fel/pins-fel.env"

PREFIX="${PREFIX:-$PWD/fel-prefix}"
WORK="${WORK:-$PWD/fel-work}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_PATCHES_DIR="$REPO_ROOT/deps-fel/ffmpeg"

CROSS=0
[ "${1:-}" = "--cross" ] && CROSS=1
[ "${MINGW:-0}" = "1" ] && CROSS=1
CROSS_PREFIX="${CROSS_PREFIX:-x86_64-w64-mingw32-}"
RUST_TARGET="${RUST_TARGET:-x86_64-pc-windows-gnu}"

# pkg-config the rest of the build will consult; our $PREFIX must win so the
# dv-fel libplacebo shadows any system/Martchus libplacebo (the classic FEL trap).
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PREFIX/bin:$PATH"

mkdir -p "$WORK" "$PREFIX"
log(){ printf '\n>> %s\n' "$*"; }

if [ "$CROSS" = 1 ]; then
    [ -n "${CROSS_FILE:-}" ] || { echo "!! --cross needs CROSS_FILE=<meson cross-file>" >&2; exit 2; }
    PKGCONFIG="${CROSS_PREFIX}pkg-config"
    log "cross mode: prefix=$CROSS_PREFIX cross-file=$CROSS_FILE rust-target=$RUST_TARGET"
else
    PKGCONFIG="pkg-config"
    log "native mode"
fi

# ---------------------------------------------------------------------------
# 1. libdovi (quietvoid/dovi_tool, dolby_vision crate) via cargo-c.
#    Skipped if a usable libdovi is already discoverable, or SKIP_LIBDOVI=1.
# ---------------------------------------------------------------------------
if [ "${SKIP_LIBDOVI:-0}" = 1 ] || "$PKGCONFIG" --exists dovi 2>/dev/null; then
    log "libdovi already present ($("$PKGCONFIG" --modversion dovi 2>/dev/null || echo external)) — skipping"
else
    log "libdovi (cargo cinstall)"
    command -v cargo-cinstall >/dev/null 2>&1 || cargo install cargo-c --locked
    if [ ! -d "$WORK/dovi_tool/.git" ]; then
        git clone https://github.com/quietvoid/dovi_tool.git "$WORK/dovi_tool"
    fi
    capi_args=(--release --prefix="$PREFIX" --libdir="$PREFIX/lib")
    if [ "$CROSS" = 1 ]; then
        rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
        capi_args+=(--target "$RUST_TARGET")
    fi
    ( cd "$WORK/dovi_tool/dolby_vision" && cargo cinstall "${capi_args[@]}" )
fi

# ---------------------------------------------------------------------------
# 2. libplacebo dv-fel (API >= 367) — follow HEAD (kasper93 force-pushes).
# ---------------------------------------------------------------------------
log "libplacebo $LIBPLACEBO_REF"
if [ ! -d "$WORK/libplacebo/.git" ]; then
    git clone --branch "$LIBPLACEBO_REF" --recurse-submodules "$LIBPLACEBO_URL" "$WORK/libplacebo"
else
    git -C "$WORK/libplacebo" fetch origin "$LIBPLACEBO_REF"
    git -C "$WORK/libplacebo" reset --hard "origin/$LIBPLACEBO_REF"
    git -C "$WORK/libplacebo" submodule update --init --recursive
fi
PLACEBO_SHA="$(git -C "$WORK/libplacebo" rev-parse --short HEAD)"

pl_args=(--prefix="$PREFIX" --buildtype=release
         -Dvulkan=enabled -Dshaderc=enabled -Dlcms=enabled
         -Ddovi=enabled -Dlibdovi=enabled -Ddemos=false)
[ "$CROSS" = 1 ] && pl_args+=(--cross-file="$CROSS_FILE")

rm -rf "$WORK/libplacebo/build"
meson setup "$WORK/libplacebo/build" "$WORK/libplacebo" "${pl_args[@]}"
ninja -C "$WORK/libplacebo/build"
ninja -C "$WORK/libplacebo/build" install

pl_ver="$("$PKGCONFIG" --modversion libplacebo)"
log "libplacebo $pl_ver installed (sha=$PLACEBO_SHA)"
# 7.370 corresponds to PL_API_VER 367 (the FEL gate). Refuse anything older.
"$PKGCONFIG" --atleast-version=7.370 libplacebo || {
    echo "!! libplacebo $pl_ver lacks the FEL API (need >= 7.370 / PL_API_VER 367)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. ffmpeg + dovi_split BSF (vendored patch).
# ---------------------------------------------------------------------------
log "ffmpeg $FFMPEG_REF + dovi_split"
if [ ! -d "$WORK/ffmpeg/.git" ]; then
    git clone --branch "$FFMPEG_REF" "$FFMPEG_URL" "$WORK/ffmpeg"
fi
git -C "$WORK/ffmpeg" reset --hard -q "origin/${FFMPEG_REF##*/}" 2>/dev/null || true
git -C "$WORK/ffmpeg" clean -fdx >/dev/null 2>&1 || true
shopt -s nullglob
for p in "$FFMPEG_PATCHES_DIR"/*.patch; do
    echo "   - applying $(basename "$p")"
    git -C "$WORK/ffmpeg" apply --3way "$p"
done

ff_args=(--prefix="$PREFIX" --enable-shared --disable-static
         --enable-gpl --enable-version3 --disable-doc)
if [ "$CROSS" = 1 ]; then
    ff_args+=(--enable-cross-compile --cross-prefix="$CROSS_PREFIX"
              --arch=x86_64 --target-os=mingw32
              --pkg-config="$PKGCONFIG")
fi
( cd "$WORK/ffmpeg" && ./configure "${ff_args[@]}" )
make -C "$WORK/ffmpeg" -j"$JOBS"
make -C "$WORK/ffmpeg" install

# Run the freshly built ffmpeg CLI against ITS OWN libavcodec (LD_LIBRARY_PATH),
# not whatever libavcodec happens to be on the system loader path — otherwise the
# check silently inspects the wrong (dovi_split-less) library. Native only; under
# cross there is no runnable host ffmpeg, so we trust the configure/compile of the
# BSF instead.
if [ "$CROSS" = 0 ]; then
    LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}" \
        "${PREFIX}/bin/ffmpeg" -hide_banner -bsfs 2>/dev/null | grep -q dovi_split \
        || { echo "!! dovi_split BSF missing from built ffmpeg" >&2; exit 1; }
    log "ffmpeg OK (dovi_split present)"
else
    grep -q dovi_split "$WORK/ffmpeg/libavcodec/bitstream_filters.c" \
        || { echo "!! dovi_split not registered in cross ffmpeg" >&2; exit 1; }
    log "ffmpeg cross-built (dovi_split registered)"
fi

cat <<EOF

=== FEL deps ready in: $PREFIX ===
  libplacebo $pl_ver (dv-fel $PLACEBO_SHA, API >= 367)
  ffmpeg     $FFMPEG_REF + dovi_split
  libdovi    $("$PKGCONFIG" --modversion dovi 2>/dev/null || echo present)

Link your mpv build against it:
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:\$PKG_CONFIG_PATH"
  export PATH="$PREFIX/bin:\$PATH"
Then apply the FEL mpv patch on top of the orender tree:
  scripts/apply-patches-fel.sh
EOF

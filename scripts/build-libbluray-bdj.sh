#!/usr/bin/env bash
# Build libbluray from source with BD-J support (libbluray.jar + JVM linkage)
# into a prefix. For macOS / Linux native builds (use build-libbluray-mingw.sh
# for the Windows cross build).
#
# Why BD-J matters: libbluray has a Java-based Blu-ray menu engine (BD-J /
# Blu-ray Disc Java); discs using BD-J (most Disney/UHD, many catalog titles)
# show a top-level "Please visit http://www.java.com" warning and skip the
# interactive menu unless libbluray is built with bdj_jar=enabled and the
# process can dlopen a JVM at runtime. This builds libbluray with the JAR
# and installs both the .dylib/.so and libbluray.jar next to it.
#
# Runtime: the consumer app needs either:
#   - JAVA_HOME set to a JDK (JRE is enough — libjvm is dlopen'd from
#     $JAVA_HOME/lib/server/ or ../Home/lib/server on macOS), OR
#   - a bundled JRE next to the binary (the CI package step also copies a
#     slim jlink runtime when possible).
#
# Env:
#   PREFIX        install prefix (default: $PWD/fel-prefix)
#   JAVA_HOME     path to JDK (REQUIRED unless a system java is discoverable)
#   LIBBLURAY_VER libbluray release to build (default 1.4.1)
#   BDJ_JAR       enabled|auto|disabled (default: enabled — build the jar)
#   BDJ_TYPE      j2se|j2me (default: j2se — Java SE profile)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$PWD/fel-prefix}"
LIBBLURAY_VER="${LIBBLURAY_VER:-1.4.1}"
BDJ_JAR="${BDJ_JAR:-enabled}"
BDJ_TYPE="${BDJ_TYPE:-j2se}"
JOBS="${JOBS:-$(uname -s | grep -q Darwin && sysctl -n hw.ncpu || nproc)}"

mkdir -p "$PREFIX"

log(){ printf '\n>> %s\n' "$*"; }

# --- resolve JAVA_HOME -------------------------------------------------------
# libbluray's meson needs `jdk_home` set AND the include/jni.h headers
# present for the native BD-J glue (bdj/*.c) to compile. We prefer an
# explicit JAVA_HOME from the CI, then try /usr/libexec/java_home (macOS)
# then fall back to a system java from PATH.
if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/include/jni.h" ]; then
    : # already good
else
    if [ "$(uname -s)" = "Darwin" ] && command -v /usr/libexec/java_home >/dev/null 2>&1; then
        mac_jh="$(/usr/libexec/java_home 2>/dev/null || true)"
        if [ -n "$mac_jh" ] && [ -f "$mac_jh/include/jni.h" ]; then
            export JAVA_HOME="$mac_jh"
        fi
    fi
fi
# Final check: meson will fail loudly if jni.h is missing; skip BDJ if we
# can't find a JDK (emit a warning so the CI job is still buildable without
# BD-J on a stripped runner).
if [ "${BDJ_JAR}" = "enabled" ] && [ ! -f "${JAVA_HOME:-/does/not/exist}/include/jni.h" ]; then
    echo "!! JAVA_HOME ($JAVA_HOME) has no include/jni.h — forcing bdj_jar=disabled" >&2
    echo "   Install a JDK or point JAVA_HOME at one to enable BD-J menus." >&2
    BDJ_JAR="disabled"
fi
log "libbluray ${LIBBLURAY_VER} (bdj_jar=${BDJ_JAR} jdk_home=${JAVA_HOME:-<system>} bdj_type=${BDJ_TYPE})"

# --- fetch & build ----------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

url="https://download.videolan.org/pub/videolan/libbluray/${LIBBLURAY_VER}/libbluray-${LIBBLURAY_VER}.tar.xz"
curl -fsSL -o "$work/libbluray.tar.xz" "$url"
tar -C "$work" -xf "$work/libbluray.tar.xz"
cd "$work/libbluray-${LIBBLURAY_VER}"

meson_args=(
  --prefix="$PREFIX"
  --libdir=lib
  --buildtype=release
  -Ddefault_library=shared
  -Dbdj_jar="${BDJ_JAR}"
  -Dbdj_type="${BDJ_TYPE}"
  -Denable_tools=false
  -Denable_examples=false
  -Denable_docs=false
  -Dlibxml2=auto
  -Dfontconfig=auto
  -Dfreetype=auto
)
[ "${BDJ_JAR}" = "enabled" ] && [ -n "${JAVA_HOME:-}" ] && meson_args+=(-Djdk_home="${JAVA_HOME}")

# If a cross-file was set (e.g. Linux arm cross), honour it
[ -n "${CROSS_FILE:-}" ] && meson_args+=(--cross-file "$CROSS_FILE")

rm -rf _b
meson setup _b "${meson_args[@]}"
ninja -C _b -j"$JOBS"
ninja -C _b install

# --- verification -----------------------------------------------------------
# libbluray itself
if [ "$(uname -s)" = "Darwin" ]; then
    dylib="$(ls "$PREFIX/lib/libbluray"*.dylib 2>/dev/null | head -1 || true)"
    [ -n "$dylib" ] || { echo "!! libbluray dylib not installed" >&2; exit 1; }
else
    so="$(ls "$PREFIX/lib/libbluray.so"* 2>/dev/null | head -1 || true)"
    [ -n "$so" ] || { echo "!! libbluray shared library not installed" >&2; exit 1; }
fi
# pkg-config
pkg-config --exists libbluray \
  || { echo "!! libbluray.pc not visible" >&2; PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH" pkg-config --exists libbluray || exit 1; }
# libbluray.jar when enabled
if [ "${BDJ_JAR}" = "enabled" ]; then
    jar="$PREFIX/share/libbluray/libbluray.jar"
    if [ -f "$jar" ]; then
        log "libbluray.jar: $(basename "$jar") ($(du -h "$jar" | cut -f1))"
    else
        echo "!! expected libbluray.jar at $jar not found (meson install step?)" >&2
        exit 1
    fi
fi

cat <<EOF

=== libbluray ready in: $PREFIX ===
  version    : $LIBBLURAY_VER
  shared lib : ${dylib:-${so:-<built>}}
  BD-J       : $BDJ_JAR${BDJ_JAR:+ (via JAVA_HOME=${JAVA_HOME:-<system>})}
  jar        : ${jar:-<disabled>}
EOF

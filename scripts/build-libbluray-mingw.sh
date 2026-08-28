#!/usr/bin/env bash
# Build libbluray from source into the MinGW cross sysroot, WITH its vendored
# libudfread (BD-ISO / UDF image support) statically embedded, AND (when a
# JDK is available) WITH BD-J JAR for Blu-ray interactive menus.
#
# Why BD-J on MinGW matters: cross-building the jar for MinGW needs a host
# javac (the .class files and .jar are cross-platform — the JDK is just the
# toolchain). Enabling it in the cross build produces a libbluray.dll that
# dlopen(s) jvm.dll at runtime (from the Windows user's JRE install), with
# libbluray.jar installed next to it so libbluray's loader finds it.
#
# Use: drop `mingw-w64-libbluray` from the pacman install and run this instead.
# It installs over the same MinGW prefix, so mpv's meson finds it via
# pkg-config. libdvdnav/libdvdread (DVD, incl. ISO) still come from Martchus —
# they read disc images natively and need no rebuild.
#
# Env:
#   CROSS_FILE      meson cross-file for x86_64-w64-mingw32 (required)
#   SYS             MinGW sysroot / install prefix (default /usr/x86_64-w64-mingw32)
#   LIBBLURAY_VER   libbluray release to build (default 1.4.1, matches Martchus)
#   JAVA_HOME       path to a host JDK (optional; BDJ jar built when present)
#   BDJ_JAR         enabled|auto|disabled (default: auto — enabled iff JAVA_HOME set)
set -euo pipefail

: "${CROSS_FILE:?set CROSS_FILE to the meson mingw cross-file}"
SYS="${SYS:-/usr/x86_64-w64-mingw32}"
LIBBLURAY_VER="${LIBBLURAY_VER:-1.4.1}"
HOST=x86_64-w64-mingw32

# --- resolve BDJ ------------------------------------------------------------
# Cross-compiling the jar: javac runs on the HOST (Linux x86_64) and emits
# portable .class files. The native BD-J C glue (bdj/register.c etc.) uses
# the host jni.h for struct layouts only; on MinGW the resulting DLL looks
# for jvm.dll at runtime. For the user to get interactive menus their
# Windows machine needs a JRE/JDK install (jre/bin/server/jvm.dll on PATH).
if [ -z "${BDJ_JAR:-}" ]; then
    if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/include/jni.h" ]; then
        BDJ_JAR=enabled
    else
        BDJ_JAR=disabled
    fi
fi
if [ "${BDJ_JAR}" = "enabled" ] && [ ! -f "${JAVA_HOME:-/does/not/exist}/include/jni.h" ]; then
    echo "!! BDJ_JAR=enabled but JAVA_HOME ($JAVA_HOME) has no include/jni.h" >&2
    BDJ_JAR=disabled
fi

# --- MinGW cross JNI workaround ----------------------------------------------
# libbluray meson computes include paths as $jdk_home/include and
# $jdk_home/include/$os_subdir (win32 for target windows). The host JDK here
# runs on Linux (inside the arch container) so $JAVA_HOME/include contains
# jni.h and the platform-specific header lives under include/linux/jni_md.h —
# but meson asks for include/win32/jni_md.h which doesn't exist.
#
# jni_md.h across Linux+Win x86_64 is functionally identical for our purposes
# (both declare jint/jlong as signed 32/64-bit, both use the same JNI
# calling-convention macros). JDK 11+ even merged the two headers for most
# platforms. Work around the missing include/win32 directory by creating it
# as a symlink to include/linux (or copy jni_md.h into it) for the build's
# duration. We leave this symlink in place — CI containers are ephemeral.
if [ "${BDJ_JAR}" = "enabled" ] && [ -n "${JAVA_HOME:-}" ]; then
    PLAT_DIR="$JAVA_HOME/include/win32"
    if [ ! -d "$PLAT_DIR" ]; then
        if [ -d "$JAVA_HOME/include/linux" ]; then
            ln -s "$JAVA_HOME/include/linux" "$PLAT_DIR" 2>/dev/null \
              || mkdir -p "$PLAT_DIR" && cp "$JAVA_HOME/include/linux/jni_md.h" "$PLAT_DIR/"
            echo "  + bdj workaround: JDK include/win32 -> include/linux (MinGW cross)"
        else
            # try darwin (unlikely but harmless)
            if [ -d "$JAVA_HOME/include/darwin" ]; then
                ln -s "$JAVA_HOME/include/darwin" "$PLAT_DIR" 2>/dev/null \
                  || mkdir -p "$PLAT_DIR" && cp "$JAVA_HOME/include/darwin/jni_md.h" "$PLAT_DIR/"
            else
                echo "!! cannot find platform-specific jni_md.h under $JAVA_HOME/include/" >&2
                ls "$JAVA_HOME/include/" || true
                exit 1
            fi
        fi
    fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

url="https://download.videolan.org/pub/videolan/libbluray/${LIBBLURAY_VER}/libbluray-${LIBBLURAY_VER}.tar.xz"
echo ">> fetching $url"
curl -fsSL -o libbluray.tar.xz "$url"
tar xf libbluray.tar.xz
cd "libbluray-${LIBBLURAY_VER}"

# default_library=shared    -> ship libbluray as a DLL (mpv links it dynamically)
# embed_udfread=true (default) -> vendored libudfread linked statically into the DLL
# bdj_jar                   -> BD-J Java menus (host JDK required for jar)
# enable_tools=false        -> skip the bd_info/etc. CLI tools we don't ship
# fontconfig/freetype/libxml2 stay at auto: resolved from $SYS via the cross
# pkg-config named in CROSS_FILE (fontconfig auto-disables on Windows by design).
meson_args=(
  --cross-file "$CROSS_FILE"
  --prefix "$SYS"
  --libdir lib
  --buildtype release
  -Ddefault_library=shared
  -Dbdj_jar="${BDJ_JAR}"
  -Denable_tools=false
  -Denable_examples=false
  -Denable_docs=false
)
# Pass jdk_home only when enabled so meson doesn't die probing a missing JDK
# on the host. The path must be the *host* JDK path (not $SYS): MinGW cross
# compiles the native C glue against the host jni.h layout, and the jar is
# built with the host javac (classes are portable).
if [ "${BDJ_JAR}" = "enabled" ] && [ -n "${JAVA_HOME:-}" ]; then
    meson_args+=(-Djdk_home="${JAVA_HOME}")
fi
meson setup _b "${meson_args[@]}"
meson compile -C _b
meson install -C _b

# --- jar relocation ---------------------------------------------------------
# See build-libbluray-bdj.sh: meson drops the jar in $SYS/share/java/ as
# libbluray-j2se-<VERSION>.jar but the runtime loader probes share/libbluray/
# libbluray.jar. Reproduce the same copy/symlink here.
if [ "${BDJ_JAR}" = "enabled" ]; then
  SHARE_JAVA="$SYS/share/java"
  BDJ_DIR="$SYS/share/libbluray"
  SRC="$(ls "$SHARE_JAVA"/libbluray-j2se-*.jar 2>/dev/null | head -1 || true)"
  if [ -n "$SRC" ]; then
    mkdir -p "$BDJ_DIR"
    cp "$SRC" "$BDJ_DIR/libbluray.jar"
    ln -sf "$(basename "$SRC")" "$SHARE_JAVA/libbluray.jar" 2>/dev/null || true
    echo "  + placed $BDJ_DIR/libbluray.jar (from $(basename "$SRC"), $(du -h "$BDJ_DIR/libbluray.jar" | cut -f1))"
  else
    echo "!! meson install produced no libbluray-j2se-*.jar under $SHARE_JAVA" >&2
    ls -la "$SHARE_JAVA" || true
    exit 1
  fi
fi

# `meson setup` above would already have failed if libudfread were unavailable
# (the dependency() call is not optional). Assert the DLL + .pc actually landed
# so the mpv build that follows finds them.
dll="$(ls "$SYS"/bin/libbluray*.dll 2>/dev/null | head -1 || true)"
test -n "$dll" || { echo "!! libbluray DLL not installed into $SYS/bin" >&2; exit 1; }
"${HOST}-pkg-config" --exists libbluray \
  || { echo "!! libbluray.pc not visible to the MinGW pkg-config" >&2; exit 1; }

# libbluray.jar verification when BDJ was enabled
if [ "${BDJ_JAR}" = "enabled" ]; then
    jar="$SYS/share/libbluray/libbluray.jar"
    if [ -f "$jar" ]; then
        echo "OK: libbluray.jar ($(du -h "$jar" | cut -f1))"
    else
        echo "!! libbluray.jar not found at $jar (meson install?)" >&2
        exit 1
    fi
fi

echo "OK: installed $(basename "$dll") (libbluray ${LIBBLURAY_VER} + embedded libudfread, BD-J: ${BDJ_JAR})"

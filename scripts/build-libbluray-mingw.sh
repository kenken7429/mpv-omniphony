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
    SRC_H=""
    if   [ -f "$JAVA_HOME/include/linux/jni_md.h"  ]; then SRC_H="$JAVA_HOME/include/linux/jni_md.h"
    elif [ -f "$JAVA_HOME/include/darwin/jni_md.h" ]; then SRC_H="$JAVA_HOME/include/darwin/jni_md.h"
    fi
    if [ -z "$SRC_H" ]; then
        echo "!! cannot find platform-specific jni_md.h under $JAVA_HOME/include/" >&2
        ls "$JAVA_HOME/include/" || true
        exit 1
    fi
    # Early exit: include/win32/jni_md.h already usable.
    # In JDK 26+ (Arch openjdk) include/win32 is often a symlink to include/linux.
    # We treat the workaround as unnecessary whenever the destination file
    # already exists AND resolves to the same inode as $SRC_H (via readlink -f
    # and inode comparison) — this prevents "cp: src and dest are the same
    # file" errors that otherwise happen on newer JDK layouts.
    if [ -f "$PLAT_DIR/jni_md.h" ]; then
        SAME_INODE=0
        if command -v readlink >/dev/null 2>&1 && command -v stat >/dev/null 2>&1; then
            A="$(readlink -f "$SRC_H"      2>/dev/null || echo "$SRC_H")"
            B="$(readlink -f "$PLAT_DIR/jni_md.h" 2>/dev/null || echo "$PLAT_DIR/jni_md.h")"
            if [ -n "$A" ] && [ "$A" = "$B" ]; then
                SAME_INODE=1
            else
                INO_A="$(stat -c '%i' "$A" 2>/dev/null || stat -f '%i' "$A" 2>/dev/null || echo 0)"
                INO_B="$(stat -c '%i' "$B" 2>/dev/null || stat -f '%i' "$B" 2>/dev/null || echo 0)"
                if [ "$INO_A" != "0" ] && [ "$INO_A" = "$INO_B" ]; then SAME_INODE=1; fi
            fi
        fi
        if [ "$SAME_INODE" -eq 1 ]; then
            echo "  + bdj: JDK include/win32/jni_md.h already present (symlink -> src, no workaround needed)"
        else
            echo "  + bdj: JDK include/win32/jni_md.h already present (different content from linux/darwin; left untouched)"
        fi
    elif [ ! -d "$PLAT_DIR" ]; then
        # Workaround case A: directory $PLAT_DIR does not exist at all.
        # Prefer symlink (cheap & clean); fall back to plain copy when the
        # filesystem doesn't support symlinks (rare on Linux CI containers).
        SRC_SUBDIR="$(dirname "$SRC_H")"
        if ! ln -s "$SRC_SUBDIR" "$PLAT_DIR" 2>/dev/null; then
            mkdir -p "$PLAT_DIR"
            cp "$SRC_H" "$PLAT_DIR/"
        fi
        echo "  + bdj workaround: JDK include/win32 -> $(basename "$SRC_SUBDIR") (MinGW cross)"
    else
        # Workaround case B: directory exists but jni_md.h is missing.
        # Only copy when src != dest (defense in depth — already excluded
        # above but belt-and-braces against any unusual layout).
        if [ "$(readlink -f "$SRC_H" 2>/dev/null)" != "$(readlink -f "$PLAT_DIR/jni_md.h" 2>/dev/null)" ]; then
            cp "$SRC_H" "$PLAT_DIR/"
            echo "  + bdj workaround: copied jni_md.h into include/win32 (dir existed)"
        else
            echo "  + bdj: JDK include/win32/jni_md.h already present (case B, skip copy)"
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

# --- VFSCache patch: auto-cache BDMV/JAR/ subdirectories -------------------
# Same fix as build-libbluray-bdj.sh: some DIY BD-J discs (SGNB/Athena/nn
# release groups) store menu resources in subdirectories under BDMV/JAR/
# (e.g. 03001/projectsettings.xml) without declaring them as DIRECTORY
# entries in the BDJO AppCache list. VFSCache.add() only caches what
# AppCache declares, so the MenuXlet gets FileNotFoundException -> NPE.
# Patch add() to also scan and cache any subdirectories found under
# BDMV/JAR/.
VFS_FILE="src/libbluray/bdj/java/org/videolan/VFSCache.java"
if grep -q 'auto-cached JAR subdirectory' "$VFS_FILE" 2>/dev/null; then
    echo ">> VFSCache patch already applied"
else
    python3 - "$VFS_FILE" <<'PATCHVFSCACHE'
import sys
f = sys.argv[1]
code = open(f).read()
old = """        }
        }
    }

    protected File addFont"""
new = """        }
        // Auto-cache BDMV/JAR/ subdirectories not declared in AppCache.
        // Some DIY BD-J discs store menu resources in subdirectories
        // (e.g. 03001/projectsettings.xml) without declaring them as
        // DIRECTORY entries in the BDJO, causing NPE in MenuXlet.
        String[] jarEntries = Libbluray.listBdFiles(jarDir, true);
        if (jarEntries != null) {
            for (int j = 0; j < jarEntries.length; j++) {
                String entry = jarEntries[j];
                String entryPath = jarDir + entry;
                String[] subFiles = Libbluray.listBdFiles(entryPath, true);
                if (subFiles != null) {
                    copyJarDir(entry);
                    logger.info("auto-cached JAR subdirectory: " + entry);
                }
            }
        }
        }
    }

    protected File addFont"""
if old not in code:
    print("ERROR: could not find add() method pattern in VFSCache.java")
    sys.exit(1)
code = code.replace(old, new, 1)
open(f, 'w').write(code)
print("VFSCache patched: auto-cache BDMV/JAR/ subdirectories")
PATCHVFSCACHE
    echo ">> VFSCache patched: auto-cache BDMV/JAR/ subdirectories"
fi

meson setup _b "${meson_args[@]}"
meson compile -C _b
meson install -C _b

# --- jar relocation ---------------------------------------------------------
# See build-libbluray-bdj.sh for the full story. Short version: meson drops
# TWO jars into $SYS/share/java/:
#   libbluray-<TYPE>-<VERSION>.jar       (main; patched into java.base)
#   libbluray-awt-<TYPE>-<VERSION>.jar   (awt-only; patched into java.desktop)
# The AWT jar is required because libbluray's _find_libbluray_jar1() rebuilds
# its name by slicing the versioned j2se jar name; if it returns NULL the
# main jar is also freed and the disc reports "libbluray.jar: 0" despite
# LIBBLURAY_CP being set correctly.
BDJ_TYPE="${BDJ_TYPE:-j2se}"
if [ "${BDJ_JAR}" = "enabled" ]; then
  SHARE_JAVA="$SYS/share/java"
  BDJ_DIR="$SYS/share/libbluray"
  SRC_J2SE="$(ls "$SHARE_JAVA"/libbluray-"${BDJ_TYPE}"-*.jar 2>/dev/null | head -1 || true)"
  SRC_AWT="$(ls "$SHARE_JAVA"/libbluray-awt-"${BDJ_TYPE}"-*.jar 2>/dev/null | head -1 || true)"
  if [ -n "$SRC_J2SE" ]; then
    mkdir -p "$BDJ_DIR"
    J2SE_BASE="$(basename "$SRC_J2SE")"
    cp -p "$SRC_J2SE" "$BDJ_DIR/$J2SE_BASE"
    if [ -n "$SRC_AWT" ]; then
      AWT_BASE="$(basename "$SRC_AWT")"
      cp -p "$SRC_AWT" "$BDJ_DIR/$AWT_BASE"
    else
      echo "!! meson install produced no libbluray-awt-${BDJ_TYPE}-*.jar under $SHARE_JAVA" >&2
      ls -la "$SHARE_JAVA" || true
      exit 1
    fi
    cp -p "$SRC_J2SE" "$BDJ_DIR/libbluray.jar"
    ln -sf "$J2SE_BASE" "$SHARE_JAVA/libbluray.jar" 2>/dev/null || true
    echo "  + placed ${J2SE_BASE} + ${AWT_BASE} under $BDJ_DIR (libbluray.jar as unversioned fallback)"
    echo "      j2se : $(du -h "$BDJ_DIR/$J2SE_BASE" | cut -f1)"
    echo "      awt  : $(du -h "$BDJ_DIR/$AWT_BASE" | cut -f1)"
  else
    echo "!! meson install produced no libbluray-${BDJ_TYPE}-*.jar under $SHARE_JAVA" >&2
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

# libbluray.jar verification when BDJ was enabled: check BOTH versioned j2se
# and awt jars exist alongside the unversioned libbluray.jar fallback. See
# long comment in build-libbluray-bdj.sh jar relocation block for why both
# versioned names matter.
if [ "${BDJ_JAR}" = "enabled" ]; then
    jar_j2se="$(ls "$SYS/share/libbluray/libbluray-${BDJ_TYPE}"-*.jar 2>/dev/null | grep -v awt | head -1 || true)"
    jar_awt="$(ls  "$SYS/share/libbluray/libbluray-awt-${BDJ_TYPE}"-*.jar 2>/dev/null | head -1 || true)"
    jar_fb="$SYS/share/libbluray/libbluray.jar"
    ok=1
    if [ -z "$jar_j2se" ] || [ ! -f "$jar_j2se" ]; then
      echo "!! versioned j2se jar missing under $SYS/share/libbluray/" >&2; ok=0
    fi
    if [ -z "$jar_awt" ] || [ ! -f "$jar_awt" ]; then
      echo "!! versioned awt jar missing under $SYS/share/libbluray/"  >&2; ok=0
    fi
    if [ ! -f "$jar_fb" ]; then
      echo "!! unversioned libbluray.jar fallback missing at $jar_fb" >&2; ok=0
    fi
    if [ "$ok" = "1" ]; then
      echo "OK: BDJ jars (via share/libbluray/):"
      echo "  j2se : $jar_j2se  ($(du -h "$jar_j2se" | cut -f1))"
      echo "  awt  : $jar_awt   ($(du -h "$jar_awt" | cut -f1))"
      echo "  fb   : $jar_fb   ($(du -h "$jar_fb" | cut -f1))"
    else
      echo "   contents of $SYS/share/libbluray/:" >&2; ls -la "$SYS/share/libbluray/" || true
      exit 1
    fi
fi

echo "OK: installed $(basename "$dll") (libbluray ${LIBBLURAY_VER} + embedded libudfread, BD-J: ${BDJ_JAR})"

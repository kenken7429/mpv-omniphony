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

# --- VFSCache patch: auto-cache BDMV/JAR/ subdirectories -------------------
# Some DIY BD-J discs (SGNB/Athena/nn release groups) store menu resources
# (projectsettings.xml, bluray_project.bin, button images, etc.) in
# subdirectories under BDMV/JAR/ (e.g. 03001/) but don't declare them as
# DIRECTORY entries in the BDJO AppCache list. VFSCache.add() only caches
# what AppCache declares, so the MenuXlet gets FileNotFoundException → NPE
# when reading from the VFS cache path. Patch add() to also scan and cache
# any subdirectories found under BDMV/JAR/.
VFS_FILE="src/libbluray/bdj/java/org/videolan/VFSCache.java"
if grep -q 'auto-cached JAR subdirectory' "$VFS_FILE" 2>/dev/null; then
    log "VFSCache patch already applied"
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
    log "VFSCache patched: auto-cache BDMV/JAR/ subdirectories"
fi

# --- bd_select_rate export patch -------------------------------------------
# When a BD-J Xlet prefetches a playlist (bd_play_playlist_at), libbluray sets
# bdj_wait_start=1 and bd_read_ext() returns BD_EVENT_IDLE(1) + 0 bytes until
# the host calls bd_select_rate(bd, 1.0, BDJ_PLAYBACK_START). mpv needs this
# to start BD-J playback after a menu item is clicked — without it, mpv sees
# EOF and exits. libbluray builds with gnu_symbol_visibility='hidden', so
# bd_select_rate (declared BD_PRIVATE in bluray_internal.h) is NOT exported
# from the shared library. Promote it to a public API: declare it in bluray.h
# with BD_PUBLIC and annotate the definition so the symbol is visible to mpv.
BLURAY_H="src/libbluray/bluray.h"
BLURAY_C="src/libbluray/bluray.c"
if grep -q 'bd_select_rate(BLURAY \*bd, float rate, int reason)' "$BLURAY_H" 2>/dev/null; then
    log "bd_select_rate export patch already applied"
else
    python3 - "$BLURAY_H" "$BLURAY_C" <<'PATCHSELECTRATE'
import sys
h_path, c_path = sys.argv[1:3]

h = open(h_path).read()
anchor = "BD_PUBLIC int  bd_play_title(BLURAY *bd, unsigned title);"
decl = anchor + """

/**
 *
 *  BD-J: start / stop playback rate.
 *
 *  When a BD-J Xlet prefetches a playlist via bd_play_playlist_at(), playback
 *  does not actually start until the application calls bd_select_rate() with
 *  reason BDJ_PLAYBACK_START (rate 1.0 = normal speed). Until then,
 *  bd_read_ext() returns BD_EVENT_IDLE(1) and 0 bytes.
 *
 *  NOTE: reason constants are NOT exposed here (bluray_internal.h already
 *  defines BDJ_PLAYBACK_START=1 / BDJ_PLAYBACK_STOP=2 in an enum; defining
 *  macros with the same names here would break bluray.c which includes both
 *  headers). Callers outside libbluray pass the literal values.
 *
 * @param bd     BLURAY object
 * @param rate   playback rate (1.0 = normal speed)
 * @param reason 1 = BDJ_PLAYBACK_START (start prefetched playlist), 2 = stop
 */
BD_PUBLIC void bd_select_rate(BLURAY *bd, float rate, int reason);"""
if anchor not in h:
    print("ERROR: could not find bd_play_title() declaration in bluray.h")
    sys.exit(1)
h = h.replace(anchor, decl, 1)
open(h_path, 'w').write(h)

c = open(c_path).read()
old = "void bd_select_rate(BLURAY *bd, float rate, int reason)"
new = "BD_PUBLIC void bd_select_rate(BLURAY *bd, float rate, int reason)"
if old not in c:
    print("ERROR: could not find bd_select_rate() definition in bluray.c")
    sys.exit(1)
c = c.replace(old, new, 1)
open(c_path, 'w').write(c)
print("bd_select_rate exported: bluray.h declaration + bluray.c BD_PUBLIC")
PATCHSELECTRATE
    log "bd_select_rate exported (bluray.h + bluray.c)"
fi

rm -rf _b
meson setup _b "${meson_args[@]}"
ninja -C _b -j"$JOBS"
ninja -C _b install

# --- jar relocation ---------------------------------------------------------
# libbluray 1.4.1 meson installs TWO BD-J jars to $PREFIX/share/java/:
#   libbluray-<TYPE>-<VERSION>.jar    (main jar: classes for --patch-module java.base)
#   libbluray-awt-<TYPE>-<VERSION>.jar (awt jar: java.awt/sun/* classes only for java.desktop patch)
#
# BOTH jars MUST remain side by side with their meson-produced versioned names
# (NOT renamed to libbluray.jar). libbluray's _find_libbluray_jar1() in
# src/libbluray/bdj/bdj.c reconstructs the awt jar name from the main jar's
# basename by slicing off "-<TYPE>-<VERSION>.jar" and inserting "awt-":
#   cut = len(jar0) - len(VERSION) - 9
#   jar1 = jar0[:cut] + "awt-" + jar0[cut:]
# where the "- 9" accounts for "-<TYPE>-<VERSION>.jar" length. Any rename
# that breaks this string slicing silently causes jar1 to return NULL, which
# then frees classpath[0] too, producing the infamous "libbluray.jar: 0" stat.
#
# The runtime loader also probes:
#   LIBBLURAY_CP env var          (checked FIRST — we use this in wrappers)
#   $libdir/../share/java/libbluray.jar
#   <jar_paths[] hardcoded system paths>
# so we additionally:
#   (a) copy BOTH versioned jars verbatim into $PREFIX/share/libbluray/, and
#   (b) create a $PREFIX/share/libbluray/libbluray.jar COPY of the main j2se
#       jar as a last-resort fallback for loaders that only know the unversioned
#       name (wrappers must still prefer LIBBLURAY_CP pointing at the
#       VERSIONED main jar so the string-slicing trick works).
if [ "${BDJ_JAR}" = "enabled" ]; then
  SHARE_JAVA="$PREFIX/share/java"
  BDJ_DIR="$PREFIX/share/libbluray"
  SRC_J2SE="$(ls "$SHARE_JAVA"/libbluray-"${BDJ_TYPE}"-*.jar 2>/dev/null | head -1 || true)"
  SRC_AWT="$(ls "$SHARE_JAVA"/libbluray-awt-"${BDJ_TYPE}"-*.jar 2>/dev/null | head -1 || true)"
  if [ -n "$SRC_J2SE" ]; then
    mkdir -p "$BDJ_DIR"
    J2SE_BASE="$(basename "$SRC_J2SE")"
    AWT_BASE=""
    # Copy the versioned main jar VERBATIM (keep name intact for jar1 slicing).
    cp -p "$SRC_J2SE" "$BDJ_DIR/$J2SE_BASE"
    # Also copy the awt jar (produced by the same meson <custom_target>)
    # next to it. If it's missing (older libbluray builds or bdj_type=j2me
    # might not build one) then fall back: libbluray tolerates a missing awt
    # jar by printing a warning, but the Java 9+ module graph setup breaks
    # without it — so we prefer loudly failing if absent.
    if [ -n "$SRC_AWT" ]; then
      AWT_BASE="$(basename "$SRC_AWT")"
      cp -p "$SRC_AWT" "$BDJ_DIR/$AWT_BASE"
    else
      echo "!! meson install produced no libbluray-awt-${BDJ_TYPE}-*.jar under $SHARE_JAVA" >&2
      echo "   contents of share/java:" >&2
      ls -la "$SHARE_JAVA" || true
      exit 1
    fi
    # Last-resort unversioned fallback: copy main jar as plain libbluray.jar.
    # Wrappers should NOT point LIBBLURAY_CP at this copy (its name breaks
    # the jar1 slicing), but it's useful for any fallback probing paths.
    cp -p "$SRC_J2SE" "$BDJ_DIR/libbluray.jar"
    # Also make share/java/libbluray.jar findable for tools that read only that
    # path (e.g. some pkg-config based loaders).
    ln -sf "$J2SE_BASE" "$SHARE_JAVA/libbluray.jar" 2>/dev/null || true
    log "installed BDJ jars under $BDJ_DIR/"
    log "  main (java.base):  $J2SE_BASE  ($(du -h "$BDJ_DIR/$J2SE_BASE" | cut -f1))"
    log "  awt  (java.desktop): $AWT_BASE  ($(du -h "$BDJ_DIR/$AWT_BASE" | cut -f1))"
    log "  fallback (unversioned): libbluray.jar (copy of j2se)"
  else
    echo "!! meson install produced no libbluray-${BDJ_TYPE}-*.jar under $SHARE_JAVA" >&2
    echo "   contents of share/java:" >&2
    ls -la "$SHARE_JAVA" || true
    exit 1
  fi
fi

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
# libbluray.jar when enabled: check versioned j2se + awt jars first, then the
# unversioned fallback. The wrappers point LIBBLURAY_CP at the j2se versioned
# jar so libbluray's _find_libbluray_jar1() can reconstruct the awt jar name.
if [ "${BDJ_JAR}" = "enabled" ]; then
    jar_j2se="$(ls "$PREFIX/share/libbluray/libbluray-${BDJ_TYPE}"-*.jar 2>/dev/null | grep -v awt | head -1 || true)"
    jar_awt="$(ls "$PREFIX/share/libbluray/libbluray-awt-${BDJ_TYPE}"-*.jar 2>/dev/null | head -1 || true)"
    jar_fb="$PREFIX/share/libbluray/libbluray.jar"
    found_all=1
    [ -n "$jar_j2se" ] && [ -f "$jar_j2se" ] || { echo "!! versioned j2se jar missing under $PREFIX/share/libbluray/" >&2; found_all=0; }
    [ -n "$jar_awt"  ] && [ -f "$jar_awt"  ] || { echo "!! versioned awt jar missing under $PREFIX/share/libbluray/"  >&2; found_all=0; }
    [ -f "$jar_fb"   ] || { echo "!! unversioned fallback jar missing at $jar_fb" >&2; found_all=0; }
    if [ "$found_all" = "1" ]; then
        log "BD-J jars:"
        log "  j2se : $jar_j2se ($(du -h "$jar_j2se" | cut -f1))"
        log "  awt  : $jar_awt  ($(du -h "$jar_awt" | cut -f1))"
        log "  fb   : $jar_fb ($(du -h "$jar_fb" | cut -f1))"
    else
        echo "   contents of $PREFIX/share/libbluray/:" >&2; ls -la "$PREFIX/share/libbluray/" || true
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

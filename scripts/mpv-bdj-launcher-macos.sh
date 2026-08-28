#!/bin/bash
# macOS launcher shim for mpv-omniphony.app.
#
# This file is the default CFBundle executable; it sits next to mpv-bin inside
# Contents/MacOS. Its job: resolve the bundled Resources/libbluray paths
# relative to IT (NOT the caller's $PWD / Finder working directory) and export
# the three env vars libbluray probes BEFORE it dlopen()s the bundled JVM:
#
#   BLURAY_JVM_LIB_PATH   absolute path to libjvm.dylib (strongest override,
#                         bypasses dlopen heuristics)
#   LIBBLURAY_CP          absolute path to the VERSIONED j2se jar (e.g.
#                         libbluray-j2se-1.4.1.jar). This value is read FIRST
#                         in libbluray src/libbluray/bdj/bdj.c:556 via getenv.
#                         CRITICAL: the value MUST be the versioned jar name
#                         because libbluray _find_libbluray_jar1() reconstructs
#                         the sibling AWT jar filename by slicing
#                           cut = len(jar0) - len(VERSION) - 9
#                         and inserting "awt-" at the cut; if we pass the plain
#                         libbluray.jar name here, cut <= 0, awt jar lookup
#                         returns NULL, which in turn frees the main jar too,
#                         producing the infamous "libbluray.jar: 0" diagnostic.
#   JAVA_HOME             set to the bundled jre directory when unset so any
#                         fallback probes in libbluray that only know JAVA_HOME
#                         still find the bundled runtime.
#
# Users who want to use their own JDK/JRE can pre-set those env vars; we skip
# overwriting BLURAY_JVM_LIB_PATH / JAVA_HOME when they're already set.
# LIBBLURAY_CP is always pointed at the bundled versioned j2se jar because
# that jar was compiled with the exact meson/jdk from this CI build and the
# native ABI on the C side must match.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# Resolve Resources/libbluray through any .., symlinks and Finder
# translocation. cd + pwd yields an absolute path without .. segments, which
# is important because some libbluray internal FILE* open calls don't behave
# identically when given "MacOS/../Resources/..." style paths on macOS.
RES="$(cd "$HERE/../Resources/libbluray" && pwd)"

# ---------------- bundled JVM path -----------------------------------------
# Temurin jlink on macOS aarch64 puts libjvm at jre/lib/server/libjvm.dylib;
# some non-jlink JDK layouts ship the entry dylib at jre/lib/jli/libjli.dylib.
# Cover both. When the caller already pinned BLURAY_JVM_LIB_PATH externally
# (e.g. when debugging with a custom JDK), keep their value untouched.
if [ -z "${BLURAY_JVM_LIB_PATH:-}" ]; then
  if   [ -f "$RES/jre/lib/server/libjvm.dylib" ]; then
    # Resolve through realpath (again avoids path oddities inside the JVM's
    # own dlopen chain with @loader_path rewrites). macOS BSD stat doesn't
    # have readlink -f but the JRE directory structure is always real.
    export BLURAY_JVM_LIB_PATH="$(cd "$(dirname "$RES/jre/lib/server/libjvm.dylib")" && pwd)/libjvm.dylib"
  elif [ -f "$RES/jre/lib/jli/libjli.dylib" ]; then
    export BLURAY_JVM_LIB_PATH="$(cd "$(dirname "$RES/jre/lib/jli/libjli.dylib")" && pwd)/libjli.dylib"
  fi
fi

# ---------------- bundled jar path (LIBBLURAY_CP) --------------------------
# Find the meson-produced VERSIONED j2se jar. CI builds with bdj_type=j2se
# so the pattern is libbluray-j2se-*.jar; glob expansion picks the single
# file produced by the build. If the versioned jar is absent for any reason,
# fall back to the plain libbluray.jar copy (better libbluray tries than us
# silently disabling BD-J — the fallback will likely still hit the cut<=0
# issue, but we at least emit a stderr diagnostic for debugging).
J2SE_JAR="$(ls "$RES"/libbluray-j2se-*.jar 2>/dev/null | head -1 || true)"
if [ -n "$J2SE_JAR" ] && [ -f "$J2SE_JAR" ]; then
  export LIBBLURAY_CP="$J2SE_JAR"
elif [ -f "$RES/libbluray.jar" ]; then
  echo "[mpv-bdj-launcher] WARNING: versioned libbluray-j2se-*.jar missing; falling back to plain $RES/libbluray.jar (this will likely still report libbluray.jar=0 due to _find_libbluray_jar1 string slicing)." >&2
  export LIBBLURAY_CP="$RES/libbluray.jar"
fi

# ---------------- JAVA_HOME fallback ---------------------------------------
# When user hasn't pre-set JAVA_HOME, point it at the bundled jre so any
# libbluray fallback heuristics (some older libbluray versions only check
# JAVA_HOME rather than the stronger BLURAY_JVM_LIB_PATH) still succeed.
if [ -z "${JAVA_HOME:-}" ] && [ -d "$RES/jre" ]; then
  export JAVA_HOME="$RES/jre"
fi

exec "$HERE/mpv-bin" "$@"

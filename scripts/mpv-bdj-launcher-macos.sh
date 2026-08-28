#!/bin/bash
# macOS launcher shim for mpv-omniphony.app.
# This file sits next to mpv-bin inside Contents/MacOS and is the default CFBundle
# executable. It resolves the bundled Resources/libbluray paths relative to its
# own location (NOT the shell's $PWD / Finder working directory) and exports the
# three env vars libbluray probes before it dlopen()s a JVM:
#   BLURAY_JVM_LIB_PATH  absolute path to libjvm.dylib (strongest override)
#   BLURAY_CLASSPATH     absolute path to libbluray.jar
#   JAVA_HOME            set to bundled jre when unset, fallbacks libbluray probes
# Users who want to use their own JDK/JRE can pre-set those env vars; we skip
# overwriting them when they're already set (BLURAY_CLASSPATH is always pointed
# at the bundled jar though — that jar is compiled specifically for this build).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../Resources/libbluray"

# Resolve bundled libjvm.dylib. Temurin jlink on macOS aarch64 uses
# jre/lib/server/libjvm.dylib as of 21; some other layouts put the entry dylib
# at jre/lib/jli/libjli.dylib — cover both. If user already pinned
# BLURAY_JVM_LIB_PATH externally, keep their value.
if [ -z "${BLURAY_JVM_LIB_PATH:-}" ]; then
  if [ -f "$RES/jre/lib/server/libjvm.dylib" ]; then
    export BLURAY_JVM_LIB_PATH="$RES/jre/lib/server/libjvm.dylib"
  elif [ -f "$RES/jre/lib/jli/libjli.dylib" ]; then
    export BLURAY_JVM_LIB_PATH="$RES/jre/lib/jli/libjli.dylib"
  fi
fi

# Always point BLURAY_CLASSPATH at the bundled libbluray.jar — it was compiled
# during this build's meson bdj_jar step and has a matching native ABI.
if [ -f "$RES/libbluray.jar" ]; then
  export BLURAY_CLASSPATH="$RES/libbluray.jar"
fi

# JAVA_HOME fallback: only set when the user hasn't set one themselves. Some
# versions of libbluray only check JAVA_HOME/lib rather than the stronger
# BLURAY_JVM_LIB_PATH override, so setting both keeps compatibility broad.
if [ -z "${JAVA_HOME:-}" ] && [ -d "$RES/jre" ]; then
  export JAVA_HOME="$RES/jre"
fi

exec "$HERE/mpv-bin" "$@"

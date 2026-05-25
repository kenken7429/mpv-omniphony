# mpv-orender

mpv with an **Atmos audio decoder** that renders TrueHD/Atmos objects through
[`liborender`](https://github.com/mgth/Omniphony) (VBAP spatial rendering)
instead of letting FFmpeg downmix. Plain (non-Atmos) TrueHD keeps playing via
mpv's normal `ad_lavc` decoder.

This repo holds **only** the mpv-side integration: the decoder source
(`src/ad_orender.c`), the patches that wire it into the mpv build, packaging and
CI. The renderer itself (`liborender.so` + the TrueHD decoder bridge) is built
and packaged from the `Omniphony` repo (`packaging/arch/`).

> **Status:** scaffold (Phase 4). `ad_orender.c` is a first draft written
> against the verified `liborender` C API and the mpv decoder interface; the
> mpv-internal touch points (marked `MPV-API:` in the source) and the `patches/`
> still need to be produced and validated against a pinned mpv build.

## Layout

```
src/ad_orender.c        # the decoder (copied into audio/decode/ at build time)
patches/                # generated diffs vs. pinned mpv (see patches/README.md)
scripts/apply-patches.sh        # clone pinned mpv + copy source + apply patches
scripts/regenerate-patches.sh   # rebuild patches/ from the mpv fork's branch
meson-options.txt       # canonical `orender` meson feature option
packaging/PKGBUILD      # Arch package (provides/conflicts mpv)
.github/workflows/ci.yml
```

## How it fits together

1. mpv demuxes raw TrueHD access units from the container.
2. `ad_orender` feeds them to `liborender` (`orender_process`), which loads the
   TrueHD decoder bridge plugin, decodes to PCM + object metadata, and VBAP-
   renders to N-channel interleaved float.
3. The first packet resolves Atmos-vs-plain (`orender_is_spatial`): non-Atmos
   streams return an error so mpv falls back — run with `--ad=orender,lavc`.
4. The output channel map comes from `orender_channel_layout` (per-speaker
   labels → `mp_chmap`).

## Requirements

- `liborender >= 0.1` and the decoder bridge installed (the `liborender` +
  `omniphony-truehd-bridge` packages). The bridge defaults to
  `/usr/lib/orender/truehd_bridge.so`.

## Build (dev)

```sh
# 1. produce patches from your mpv fork's `orender` branch (once it exists):
scripts/regenerate-patches.sh /path/to/mpv-fork

# 2. assemble a patched mpv tree at build/mpv-<tag>:
scripts/apply-patches.sh v0.40.0

# 3. build it:
cd build/mpv-v0.40.0
meson setup _b -Dorender=enabled && meson compile -C _b
```

## Play

```sh
mpv --ad=orender,lavc film.atmos.mkv
```

Phase 4 uses compile-time defaults (7.1.4 layout, packaged bridge path). The
`--ad-orender-*` options (config path, OSC) land in Phase 5 — see the spec §6.

## mpv fork workflow

Develop the integration in a fork of `mpv-player/mpv`:

- `master` mirrors upstream (never modified).
- `orender` carries the integration commits.

```sh
git remote add upstream https://github.com/mpv-player/mpv.git
git fetch upstream
git checkout master && git merge upstream/master
git checkout orender && git rebase master       # resolve drift
scripts/regenerate-patches.sh /path/to/mpv-fork # refresh patches/ here
```

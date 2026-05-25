# mpv-orender

mpv with an **Atmos audio decoder** that renders TrueHD/Atmos objects through
[`liborender`](https://github.com/mgth/Omniphony) (VBAP spatial rendering)
instead of letting FFmpeg downmix. Plain (non-Atmos) TrueHD keeps playing via
mpv's normal `ad_lavc` decoder.

This repo holds **only** the mpv-side integration: the decoder source
(`src/ad_orender.c`), the patches that wire it into the mpv build, packaging and
CI. The renderer itself (`liborender.so` + the TrueHD decoder bridge) is built
and packaged from the `Omniphony` repo (`packaging/arch/`).

> **Status:** Phase 4, pinned to mpv **v0.41.0**. The decoder is written
> against the real mpv 0.41 decoder framework (`mp_filter`/`mp_decoder_fns`)
> and the verified `liborender` C API, and lives on the `orender` branch of the
> mpv fork (`mgth/mpv`). Validated: `meson setup -Dorender=enabled` detects
> liborender and both `ad_orender.c` and `f_decoder_wrapper.c` **compile**
> (object-level). Not yet validated: a full link + actual Atmos playback (needs
> liborender + the bridge installed) and the seek/PTS behaviour.

## Layout

```
src/ad_orender.c        # readable copy of the decoder (patch 0001 adds it to mpv)
patches/                # generated diffs vs. pinned mpv (see patches/README.md)
scripts/apply-patches.sh        # clone pinned mpv + apply patches
scripts/regenerate-patches.sh   # rebuild patches/ from the mpv fork's branch
meson-options.txt       # canonical `orender` meson feature option
packaging/PKGBUILD      # Arch package (provides/conflicts mpv)
.github/workflows/ci.yml
```

## How it fits together

1. mpv demuxes raw TrueHD access units from the container.
2. `ad_orender` feeds them to `liborender` (`orender_process`), which loads the
   TrueHD decoder bridge plugin, decodes to PCM + object metadata, and VBAP-
   renders to N-channel interleaved float (`AF_FORMAT_FLOAT` — so mpv's normal
   resampler / audio filter chain still applies, unlike spdif passthrough).
3. It's opt-in: the decoder is only selected for TrueHD when `orender` is in the
   `--ad` list, so default TrueHD playback is untouched. The first packet
   resolves Atmos-vs-plain (`orender_is_spatial`); automatic fallback to
   `ad_lavc` for non-Atmos is Phase 5.
4. The output channel map comes from `orender_channel_layout` (per-speaker
   labels → `mp_chmap`).

## Requirements

- `liborender >= 0.1` and the decoder bridge installed (the `liborender` +
  `omniphony-truehd-bridge` packages). The bridge defaults to
  `/usr/lib/orender/truehd_bridge.so`.

## Build (dev)

```sh
# 1. assemble a patched mpv tree at build/mpv-v0.41.0 (clones the pinned tag):
scripts/apply-patches.sh v0.41.0

# 2. build it (needs liborender + the bridge installed):
cd build/mpv-v0.41.0
meson setup _b -Dorender=enabled && meson compile -C _b

# (to refresh patches/ after editing the fork's `orender` branch:)
scripts/regenerate-patches.sh /path/to/mpv-fork v0.41.0
```

## Play

```sh
mpv --ad=orender film.atmos.mkv          # opt-in; default playback is untouched
```

Phase 4 uses compile-time defaults (7.1.4 layout, packaged bridge path). The
`--ad-orender-*` options (config path, OSC) and automatic non-Atmos fallback to
`ad_lavc` land in Phase 5 — see the spec §6.

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

# mpv-omniphony

mpv with an **Spatial audio decoder** that renders objects through
[`liborender`](https://github.com/mgth/Omniphony) (VBAP spatial rendering)
instead of letting FFmpeg downmix. Non spatial keeps playing via
mpv's normal `ad_lavc` decoder.

![mpv-omniphony — mpv playing a spatial mix, supervised by Omniphony Studio](mpv-omniphony.png)

*Left: mpv's stats overlay shows `ad_orender` picked up the stream and
the renderer is feeding the platform's audio output. Right: Omniphony
Studio attached over OSC, showing per-object positions in the room and
live meters.*

This repo holds **only** the mpv-side integration: the decoder source
(`src/ad_orender.c`), the patches that wire it into the mpv build, packaging and
CI. The renderer itself (`liborender.so` + the decoder bridge) is built
and packaged from the `Omniphony` repo (`packaging/arch/`).

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

1. mpv demuxes raw access units from the container.
2. `ad_orender` feeds them to `liborender` (`orender_process`), which loads the
   decoder bridge plugin, decodes to PCM + object metadata, and VBAP-
   renders to N-channel interleaved float (`AF_FORMAT_FLOAT` — so mpv's normal
   resampler / audio filter chain still applies, unlike spdif passthrough).
3. It's opt-in: the decoder is only selected for spatial audio when `orender` is in the
   `--ad` list, so default Spatial playback is untouched. The first packet
   resolves Spatial-vs-plain (`orender_is_spatial`); for non-Spatiial the
   bed is still VBAP-rendered to the layout (automatic fallback to `ad_lavc`
   is a future refinement — use plain `--ad=` to bypass orender entirely).
4. The output channel map comes from `orender_channel_layout` (per-speaker
   labels → `mp_chmap`).

## Requirements

- `liborender >= 0.1` and the decoder bridge installed (the `liborender` +
  `omniphony-spatial-bridge` packages).
- The **shared omniphony config** at `~/.config/omniphony/config.yaml` (the same
  one the `orender` CLI and studio use) providing `render.bridge_path` (the
  decoder bridge) and optionally the speaker layout. ad_orender reads this
  config — nothing is hardcoded. If you already run the CLI/studio, it works as
  is; otherwise create it with at least:
  ```yaml
  render:
    bridge_path: /usr/lib/orender/*_bridge.so
  ```

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
mpv --ad=orender film.spatial.mkv          # opt-in; default playback is untouched
```

With no options, everything (bridge path, speaker layout, OSC) comes from the
shared `~/.config/omniphony/config.yaml`. Per-invocation overrides:

| Option | Overrides |
| --- | --- |
| `--ad-orender-config=<path>` | the render config YAML (else the shared default) |
| `--ad-orender-bridge-path=<path>` | `render.bridge_path` (the decoder bridge `.so`) |
| `--ad-orender-osc` | force OSC on (else follows `render.osc` in the config) |
| `--ad-orender-osc-port=<n>` | outgoing/monitoring port |
| `--ad-orender-osc-rx-port=<n>` | incoming control port (studio registers here; default 9000) |
| `--ad-orender-osc-bind=<addr>` | listener bind address |
| `--ad-orender-osc-monitor-target=<host>` | monitoring host |

Empty/zero values fall back to the config then the built-in defaults, so the
zero-config `--ad=orender` path is unchanged. **OSC + studio:** either set
`render.osc: true` in the config or pass `--ad-orender-osc`; the renderer then
listens on 9000 (the rendezvous studio registers to) — studio connects on its
own. Note the shared config means the standalone CLI would also enable OSC.

## Supervision with Omniphony Studio

[Omniphony Studio](https://github.com/mgth/Omniphony) is the 3D
visualization / live-control UI for the renderer. It speaks OSC to whichever
host runs `liborender` — the standalone `orender` CLI, or the embedded
host inside this mpv build. Studio detects the embedded variant via the
renderer's capabilities handshake and hides the panels that don't apply
(audio-output device, adaptive resampler, latency target), keeping spatial
controls and metering enabled.

### Get Studio

Prebuilt bundles ship on the Omniphony repo's releases page:

```
https://github.com/mgth/Omniphony/releases/latest
```

- **Linux** — `Omniphony.Studio_<ver>_amd64.deb`,
  `Omniphony.Studio_<ver>_amd64.AppImage`, or
  `Omniphony.Studio-<ver>-1.x86_64.rpm`.
- **Windows** — `Omniphony.Studio_<ver>_x64-setup.exe` (NSIS) or
  `Omniphony.Studio_<ver>_x64_en-US.msi`.

The Linux .deb installs an `omniphony-studio` binary; the Windows
installers add a Start menu entry.

### Connect Studio to mpv

1. Start mpv with OSC on (one of the two — they're equivalent):
   - add `render.osc: true` to `~/.config/omniphony/config.yaml`, or
   - launch with `mpv --ad=orender --ad-orender-osc film.mkv`.
2. Launch Studio. It registers with the renderer on the rendezvous port
   (default 9000) and starts receiving the live state.

Studio also works against the standalone CLI the same way — the same shared
config drives both. You can flip between embedded (mpv) and standalone
sessions without re-configuring Studio.

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

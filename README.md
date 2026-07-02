# mpv-omniphony

mpv with a **spatial audio decoder** that renders objects through
[`liborender`](https://github.com/mgth/Omniphony) (VBAP spatial rendering)
instead of letting FFmpeg downmix. **This repository holds the mpv-side
integration and build only.**

> 📖 **Usage** (playback, Studio supervision, overlay controls) and **prebuilt
> downloads** live with the engine:
> **[Omniphony → mpv-omniphony usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md)**.

> ⭐ **mpv-omniphony is one frontend for the
> [Omniphony](https://github.com/mgth/Omniphony) spatial audio engine — the engine
> is the project.** If this is useful to you, please
> **[star the engine ↗](https://github.com/mgth/Omniphony)**.
>
> [![Star Omniphony](https://img.shields.io/github/stars/mgth/Omniphony?style=social&label=Star%20the%20engine)](https://github.com/mgth/Omniphony)

This repo holds **only** the mpv-side integration: the decoder source
(`src/ad_orender.c`), the patches that wire it into the mpv build, packaging and
CI. The renderer itself (`liborender.so` + the decoder bridge) is built and
packaged from the `Omniphony` repo (`packaging/arch/`).

mpv loads liborender at **runtime** (dlopen + ABI version handshake) — building
mpv needs no engine at all, and an updated engine (e.g. deployed by Omniphony
Studio) is picked up without rebuilding mpv. The library search order and the
`--ad-orender-library` option are documented in the
[usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md).

## Layout

```
src/ad_orender.c        # readable copy of the decoder (patch 0001 adds it to mpv)
patches/                # generated diffs vs. pinned mpv v0.41.0
patches-master/         # generated diffs vs. upstream mpv master HEAD (live tracker)
scripts/apply-patches.sh             # clone pinned mpv + apply patches/
scripts/apply-patches-master.sh      # clone mpv master HEAD + apply patches-master/
scripts/regenerate-patches.sh        # rebuild patches/ from the fork's `orender`
scripts/regenerate-patches-master.sh # rebuild patches-master/ from `orender-master`
meson-options.txt       # canonical `orender` meson feature option
packaging/PKGBUILD          # Arch package against v0.41.0 (provides/conflicts mpv)
packaging/PKGBUILD-master   # Arch -git package tracking master HEAD
.github/workflows/ci.yml             # weekly drift check on v0.41.0
.github/workflows/build-master.yml   # daily smoke test on master HEAD
```

## Build (dev)

```sh
# 1. assemble a patched mpv tree at build/mpv-v0.41.0 (clones the pinned tag):
scripts/apply-patches.sh v0.41.0

# 2. build it (no liborender needed at build time — it is dlopen'd at runtime):
cd build/mpv-v0.41.0
meson setup _b -Dorender=enabled && meson compile -C _b

# (to refresh patches/ after editing the fork's `orender` branch:)
scripts/regenerate-patches.sh /path/to/mpv-fork v0.41.0
```

Running it (playback, the shared `~/.config/omniphony/config.yaml`, OSC, Studio
supervision and the on-video overlay) is documented in the
[usage guide](https://github.com/mgth/Omniphony/blob/main/docs/mpv-omniphony.md).

## mpv fork workflow

Develop the integration in a fork of `mpv-player/mpv`:

- `master` mirrors upstream (never modified).
- `orender` carries the integration commits based on the pinned `v0.41.0` tag.
- `orender-master` carries the same commits rebased onto `upstream/master` (feeds
  `patches-master/`; rebase periodically when the daily CI flags drift).

```sh
git remote add upstream https://github.com/mpv-player/mpv.git
git fetch upstream
git checkout master && git merge upstream/master
git checkout orender && git rebase master       # resolve drift
scripts/regenerate-patches.sh /path/to/mpv-fork # refresh patches/ here
```

## Tracking mpv master

A second build path targets **upstream mpv master HEAD** (no SHA pin, live
tracker). Useful for catching breakage early and for power users who want the
freshest mpv with the orender decoder. The pinned `v0.41.0` flow above is the
stable default — the master flow may break on any upstream merge.

```sh
# Local build (clones mpv master + applies patches-master/):
scripts/apply-patches-master.sh
cd build/mpv-master-<short-sha>
meson setup _b -Dorender=enabled && meson compile -C _b
```

When the daily CI (`build-master.yml`) goes red, it means an upstream merge
collided with one of the 7 integration commits. Rebase `orender-master`:

```sh
cd /path/to/mpv-fork
git checkout orender-master
git fetch upstream
git rebase upstream/master                      # resolve conflicts
cd /path/to/mpv-omniphony
scripts/regenerate-patches-master.sh /path/to/mpv-fork
git add patches-master/ && git commit -m "patches-master: rebase onto upstream/master"
```

Packaging: `packaging/PKGBUILD-master` builds an `mpv-omniphony-git` package
that clones mpv master at install time and applies `patches-master/`. It
conflicts with both stock `mpv` and the stable `mpv-omniphony` — install one.

## License

`mpv-omniphony` is a patch-set fork of
[mpv](https://github.com/mpv-player/mpv) (**GPL-2.0-or-later**, © the mpv
authors) that adds the `ad_orender` audio decoder. `ad_orender` loads
**`liborender`** from [Omniphony](https://github.com/mgth/Omniphony) at
runtime, which is **GPL-3.0-or-later**.

- Our first-party additions — `src/ad_orender.c`, the integration commits in
  `patches/` / `patches-master/`, and the build tooling — are
  **GPL-2.0-or-later**. The bundled Steinberg ASIO output driver (`ao_asio.c`,
  added by `patches/`) keeps its **LGPL-2.1-or-later** header.
- mpv's own license files (`Copyright`, `LICENSE.GPL`, `LICENSE.LGPL`) ship
  unchanged inside the built mpv tree.

**The binaries we distribute combine GPLv2-or-later mpv with GPLv3-or-later
liborender, so the combined work is licensed `GPL-3.0-or-later`** (the GPLv2+
parts under their "or later" option). Full text: [`COPYING`](COPYING).

**Corresponding source (GPLv3 §6):** each release ships from mpv `v0.41.0` (the
pinned tag) plus this repository's `patches/`, and `liborender` built from
Omniphony at the `OMNIPHONY_REF` printed in the release notes
(<https://github.com/mgth/Omniphony>).

**Bundled third-party libraries** (ffmpeg, libplacebo, LuaJIT, …, plus the
Windows/macOS runtime libraries) retain their own licenses — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). The decoder **bridge** plugin
is not included and is licensed separately.

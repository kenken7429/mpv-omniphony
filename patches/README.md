# Patches

These `.patch` files are **generated** from the mpv fork's `orender` branch by
`scripts/regenerate-patches.sh` (`git format-patch v0.41.0..orender`). Do not
hand-edit them — edit the fork, then regenerate. `src/ad_orender.c` is the
readable copy of the decoder source from which patch 0001 is produced; keep the
two in sync.

Generated against mpv **v0.41.0** (`filters/f_decoder_wrapper.{c,h}` is the
current decoder registry; mpv ≤ 0.36's `ad_functions`/`ad.c` model is gone):

| Patch | Touches | What it does |
|-------|---------|--------------|
| `0001-audio-add-ad_orender-decoder-*.patch` | `audio/decode/ad_orender.c` | Adds the `mp_filter`/`mp_decoder_fns` decoder. |
| `0002-audio-register-ad_orender-*.patch` | `filters/f_decoder_wrapper.{c,h}` | `extern … ad_orender;` + select it for TrueHD when `--ad` lists `orender` (`HAVE_ORENDER`-guarded). |
| `0003-build-detect-orender-*.patch` | `meson.build`, `meson.options` | `orender` feature option, `dependency('orender', '>= 0.1')`, and `sources += files('audio/decode/ad_orender.c')` when found. |

Validated on v0.41.0: `meson setup -Dorender=enabled` detects liborender and
both `ad_orender.c` and `f_decoder_wrapper.c` compile (object-level). A full
link + playback is the downstream build's job (needs liborender + the bridge
installed). The meson option is also mirrored in `../meson-options.txt`.

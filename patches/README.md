# Patches

These `.patch` files are **generated** from the mpv fork's `orender` branch by
`scripts/regenerate-patches.sh` (`git format-patch master..orender`). Do not
hand-edit them — edit the fork, then regenerate.

`src/ad_orender.c` is the decoder source; `scripts/apply-patches.sh` and the
PKGBUILD copy it into `audio/decode/` before applying the patches, so the
patches only need to touch *existing* mpv files.

Expected patches (against the pinned mpv tag — see `scripts/`):

| Patch | Touches | What it does |
|-------|---------|--------------|
| `0001-add-ad-orender-decoder.patch`        | `audio/decode/ad_orender.c` | Adds the decoder source (or the script copies `src/ad_orender.c`). |
| `0002-register-ad-orender-in-decoder-list.patch` | `audio/decode/ad.c` | `extern const struct ad_functions ad_orender;` + entry in `ad_drivers[]` **before** `ad_lavc`. |
| `0003-meson-detect-orender.patch`          | `meson.build`, `meson_options.txt` | `dependency('orender', '>= 0.1')`, the `orender` feature option, and `sources += files('audio/decode/ad_orender.c')` when found. |

The meson fragment and the option are mirrored in the repo root
(`../meson-options.txt`) and in the spec (§5) so they can be reconstructed if a
patch goes stale against a new mpv release.

This directory is empty until the fork branch exists and the patches are
generated — see the top-level README for the fork workflow.

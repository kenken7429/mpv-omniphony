# Third-party notices

The `mpv-omniphony` release archives bundle the libraries listed below. Each one
keeps its own license; this file is an inventory, not a re-licensing. The
combined `mpv` binary is **GPL-3.0-or-later** — see [`COPYING`](COPYING) and the
"License" section of the [README](README.md).

> Before publishing, verify each license string against the exact version
> actually bundled (the Homebrew / MinGW / distro package that shipped the
> binary), as upstreams occasionally relicense.

| Component | Bundled on | License (SPDX — verify) | Upstream |
|---|---|---|---|
| liborender (Omniphony) | all | `GPL-3.0-or-later` | https://github.com/mgth/Omniphony |
| FFmpeg (libav*) | all | `GPL-2.0-or-later` (built `--enable-gpl --enable-version3` ⇒ effectively GPLv3) | https://ffmpeg.org |
| libass | all | `ISC` | https://github.com/libass/libass |
| libplacebo | all | `LGPL-2.1-or-later` | https://code.videolan.org/videolan/libplacebo |
| LuaJIT | all | `MIT` | https://luajit.org |
| libsrt | Windows | `MPL-2.0` | https://github.com/Haivision/srt |
| OpenSSL | Windows | `Apache-2.0` | https://www.openssl.org |
| libstdc++ / libgcc (MinGW runtime) | Windows | `GPL-3.0-or-later WITH GCC-exception-3.1` | https://gcc.gnu.org |
| libwinpthread (mingw-w64 runtime) | Windows | `Zlib`/`MIT`-style | https://www.mingw-w64.org |
| MoltenVK | macOS | `Apache-2.0` | https://github.com/KhronosGroup/MoltenVK |
| Vulkan-Loader | macOS | `Apache-2.0` | https://github.com/KhronosGroup/Vulkan-Loader |

The copyleft libraries above (FFmpeg, libplacebo, the MinGW libstdc++/libgcc
runtime) carry their own corresponding-source obligations; their sources are
available from the upstreams listed.

The decoder **bridge** plugin is **not** bundled (separate licensing — obtain it
yourself, see the README).

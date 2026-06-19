#!/usr/bin/env bash
# Build & install a MOCK liborender for CI: a header matching the public API and
# a stub .so (no-op symbols) with the real soname + a pkg-config file, so the
# patched mpv can detect, compile and link ad_orender.c. It does NOT decode
# anything — real playback is validated downstream against the actual package.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
VER=0.2.0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- header: keep field/signature shapes in sync with orender_ffi/orender.h ---
cat > "$WORK/orender.h" <<'EOF'
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct OrenderRenderer OrenderRenderer;
typedef struct OrenderConfig {
    uint32_t sample_rate;
    const char *config_yaml_path;
    const char *speaker_layout_path;
    const char *bridge_path;
    const char *codec;
    int osc_enabled;
    uint16_t osc_port_in;
    uint16_t osc_port_out;
    const char *osc_bind;
    const char *osc_host;
} OrenderConfig;
OrenderRenderer *orender_create(const OrenderConfig *cfg);
void orender_destroy(OrenderRenderer *r);
int orender_is_spatial(const OrenderRenderer *r);
uint32_t orender_channel_count(const OrenderRenderer *r);
uint32_t orender_channel_layout(const OrenderRenderer *r, uint8_t *out_labels, uint32_t cap);
int orender_channel_mode(const OrenderRenderer *r);
void orender_set_channel_mode(OrenderRenderer *r, int mode);
int orender_channel_mapping(const OrenderRenderer *r);
void orender_set_channel_mapping(OrenderRenderer *r, int mode);
int orender_object_count(const OrenderRenderer *r);
int orender_dialnorm_db(const OrenderRenderer *r);
uint32_t orender_bed_layout(const OrenderRenderer *r, uint8_t *out_labels, uint32_t cap);
void orender_reset(OrenderRenderer *r);
int orender_process(OrenderRenderer *r, const uint8_t *pkt, size_t pkt_len,
                    int64_t pts_us, float *out, size_t out_cap_samples,
                    size_t *out_frames, uint32_t *out_channels, int64_t *out_pts_us);
uint32_t orender_version_major(void);
uint32_t orender_version_minor(void);
/* In-process spatial overlay (pulled by mpv's built-in overlay client). */
uintptr_t orender_overlay_ass(uint32_t res_x, uint32_t res_y, uint8_t *out, uintptr_t cap);
void orender_overlay_set_enabled(int enabled);
void orender_overlay_set_rendering(int rendering);
void orender_overlay_clear(void);
int orender_overlay_toggle(void);
int orender_overlay_toggle_labels(void);
int orender_overlay_toggle_objects(void);
int orender_overlay_toggle_trails(void);
int orender_overlay_toggle_heatmap(void);
uint32_t orender_overlay_cycle_heatmap_colormap(void);
uint32_t orender_overlay_adjust_heatmap_bands(int32_t delta);
uintptr_t orender_overlay_heatmap_bgra(uint32_t res_x, uint32_t res_y,
                                       uint8_t *out, uintptr_t cap, int32_t *geom);
EOF

# --- stub implementation (all no-ops) ---
cat > "$WORK/stub.c" <<'EOF'
#include "orender.h"
struct OrenderRenderer { int _; };
static struct OrenderRenderer g;
OrenderRenderer *orender_create(const OrenderConfig *c){(void)c;return &g;}
void orender_destroy(OrenderRenderer *r){(void)r;}
int orender_is_spatial(const OrenderRenderer *r){(void)r;return 0;}
uint32_t orender_channel_count(const OrenderRenderer *r){(void)r;return 0;}
uint32_t orender_channel_layout(const OrenderRenderer *r,uint8_t *o,uint32_t c){(void)r;(void)o;(void)c;return 0;}
int orender_channel_mode(const OrenderRenderer *r){(void)r;return 0;}
void orender_set_channel_mode(OrenderRenderer *r,int m){(void)r;(void)m;}
int orender_channel_mapping(const OrenderRenderer *r){(void)r;return 0;}
void orender_set_channel_mapping(OrenderRenderer *r,int m){(void)r;(void)m;}
int orender_object_count(const OrenderRenderer *r){(void)r;return 0;}
int orender_dialnorm_db(const OrenderRenderer *r){(void)r;return 0;}
uint32_t orender_bed_layout(const OrenderRenderer *r,uint8_t *o,uint32_t c){(void)r;(void)o;(void)c;return 0;}
void orender_reset(OrenderRenderer *r){(void)r;}
int orender_process(OrenderRenderer *r,const uint8_t *p,size_t pl,int64_t t,
                    float *o,size_t oc,size_t *nf,uint32_t *nc,int64_t *op){
    (void)r;(void)p;(void)pl;(void)t;(void)o;(void)oc;
    if(nf)*nf=0; if(nc)*nc=0; if(op)*op=t; return 0;}
uint32_t orender_version_major(void){return 0;}
uint32_t orender_version_minor(void){return 1;}
uintptr_t orender_overlay_ass(uint32_t x,uint32_t y,uint8_t *o,uintptr_t c){(void)x;(void)y;(void)o;(void)c;return 0;}
void orender_overlay_set_enabled(int e){(void)e;}
void orender_overlay_set_rendering(int x){(void)x;}
void orender_overlay_clear(void){}
int orender_overlay_toggle(void){return 0;}
int orender_overlay_toggle_labels(void){return 0;}
int orender_overlay_toggle_objects(void){return 0;}
int orender_overlay_toggle_trails(void){return 0;}
int orender_overlay_toggle_heatmap(void){return 0;}
uint32_t orender_overlay_cycle_heatmap_colormap(void){return 0;}
uint32_t orender_overlay_adjust_heatmap_bands(int32_t d){(void)d;return 0;}
uintptr_t orender_overlay_heatmap_bgra(uint32_t x,uint32_t y,uint8_t *o,uintptr_t c,int32_t *g){(void)x;(void)y;(void)o;(void)c;(void)g;return 0;}
EOF

sudo install -Dm644 "$WORK/orender.h" "$PREFIX/include/orender.h"

cc -shared -fPIC -Wl,-soname,liborender.so.0 \
   "$WORK/stub.c" -I"$WORK" -o "$WORK/liborender.so.$VER"
sudo install -Dm755 "$WORK/liborender.so.$VER" "$PREFIX/lib/liborender.so.$VER"
sudo ln -sf "liborender.so.$VER" "$PREFIX/lib/liborender.so.0"
sudo ln -sf "liborender.so.0"    "$PREFIX/lib/liborender.so"

sudo install -d "$PREFIX/lib/pkgconfig"
sudo tee "$PREFIX/lib/pkgconfig/orender.pc" >/dev/null <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: orender
Description: Spatial audio renderer library (CI mock)
Version: $VER
Libs: -L\${libdir} -lorender
Cflags: -I\${includedir}
EOF

sudo ldconfig || true
echo ">> mock liborender installed to $PREFIX"

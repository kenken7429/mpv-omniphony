/*
 * ad_orender.c — mpv audio decoder that renders TrueHD/Atmos through liborender.
 *
 * Drop-in companion to ad_lavc.c: when the stream is TrueHD *with* Atmos
 * objects, decode + VBAP-render it to N-channel float PCM via liborender
 * (orender_*), instead of letting FFmpeg downmix. Plain (non-Atmos) TrueHD is
 * rejected so mpv falls back to ad_lavc — use `--ad=orender,lavc`.
 *
 * STATUS: first-draft scaffold (Phase 4). It is written against the public
 * liborender C API (orender.h, verified) and the mpv `ad_functions` decoder
 * interface as of the spec. The mpv-internal touch points (struct fields,
 * AD_* return codes, mp_chmap/mp_aframe helpers, talloc, AV_CODEC_ID_TRUEHD)
 * must be validated against the *pinned* mpv version this is patched into —
 * mpv's audio decode layer has shifted between releases. Lines that depend on
 * mpv internals are marked `MPV-API:`.
 *
 * Phase 4 keeps it minimal: compile-time defaults (7.1.4 layout via NULL config,
 * the packaged bridge path), no mpv options yet. Phase 5 replaces the defaults
 * block with `--ad-orender-*` options (see README / spec §6).
 */

#include "audio/aframe.h"
#include "audio/chmap.h"
#include "audio/decode/ad.h"
#include "audio/format.h"
#include "common/common.h"
#include "common/msg.h"
#include "demux/packet.h"
#include "demux/stheader.h"

#include <libavcodec/codec_id.h>   /* AV_CODEC_ID_TRUEHD */

#include <orender.h>
#include <string.h>

/* ---- Phase 4 compile-time defaults (replaced by options in Phase 5) ------- */

/* Bridge plugin: liborender has no exe-relative search when hosted in mpv, so
 * the path is explicit. This is where omniphony-truehd-bridge installs it. */
#define ORENDER_DEFAULT_BRIDGE_PATH "/usr/lib/orender/truehd_bridge.so"
/* NULL config → liborender uses the 7.1.4 preset layout + default params. */
#define ORENDER_DEFAULT_CONFIG_PATH NULL

/* ---- liborender channel labels (mirror bridge_api::RChannelLabel) ---------
 * orender_channel_layout() returns one of these bytes per output speaker.
 * Keep in sync with bridge_api/src/lib.rs (parse_deps=false, so cbindgen does
 * not emit this enum into orender.h). */
enum {
    OR_L = 0, OR_R = 1, OR_C = 2, OR_LFE = 3, OR_LS = 4, OR_RS = 5,
    OR_TFL = 6, OR_TFR = 7, OR_TSL = 8, OR_TSR = 9, OR_TBL = 10, OR_TBR = 11,
    OR_LSC = 12, OR_RSC = 13, OR_LB = 14, OR_RB = 15, OR_CB = 16, OR_TC = 17,
    OR_LSD = 18, OR_RSD = 19, OR_LW = 20, OR_RW = 21, OR_TFC = 22, OR_LFE2 = 23,
    OR_UNKNOWN = 255,
};

struct priv {
    struct mp_log *log;
    OrenderRenderer *renderer;
    int sample_rate;
    int channels;            /* speaker count from the active layout */
    struct mp_chmap chmap;   /* built once from orender_channel_layout() */
    bool checked_spatial;    /* is_spatial() resolved after the first packet */
};

/* Map a liborender label to an mpv speaker id. The 7.1.4 default layout maps
 * exactly; less common positions are best-effort.
 * MPV-API: MP_SPEAKER_ID_* names come from audio/chmap.h — confirm the top/side
 * ids exist in the pinned mpv (TSL/TSR/TC/TFC are the shaky ones). */
static int label_to_mp_speaker(uint8_t lbl)
{
    switch (lbl) {
    case OR_L:    return MP_SPEAKER_ID_FL;
    case OR_R:    return MP_SPEAKER_ID_FR;
    case OR_C:    return MP_SPEAKER_ID_FC;
    case OR_LFE:  return MP_SPEAKER_ID_LFE;
    case OR_LS:   return MP_SPEAKER_ID_SL;
    case OR_RS:   return MP_SPEAKER_ID_SR;
    case OR_LB:   return MP_SPEAKER_ID_BL;
    case OR_RB:   return MP_SPEAKER_ID_BR;
    case OR_CB:   return MP_SPEAKER_ID_BC;
    case OR_LSC:  return MP_SPEAKER_ID_FLC;
    case OR_RSC:  return MP_SPEAKER_ID_FRC;
    case OR_LW:   return MP_SPEAKER_ID_WL;
    case OR_RW:   return MP_SPEAKER_ID_WR;
    case OR_LFE2: return MP_SPEAKER_ID_LFE2;
    case OR_TFL:  return MP_SPEAKER_ID_TFL;
    case OR_TFR:  return MP_SPEAKER_ID_TFR;
    case OR_TFC:  return MP_SPEAKER_ID_TFC;
    case OR_TBL:  return MP_SPEAKER_ID_TBL;
    case OR_TBR:  return MP_SPEAKER_ID_TBR;
    case OR_TC:   return MP_SPEAKER_ID_TC;
    /* TODO(chmap): top-side L/R have no classic WAVE id; FFmpeg has
     * AV_CHAN_TOP_SIDE_{LEFT,RIGHT}. Map once confirmed in mpv's chmap.h. */
    case OR_TSL:  return MP_SPEAKER_ID_NA;
    case OR_TSR:  return MP_SPEAKER_ID_NA;
    default:      return MP_SPEAKER_ID_NA;
    }
}

/* Build p->chmap from the renderer's output layout. Returns false if the
 * layout has unmapped speakers (caller can still proceed with NA positions). */
static bool build_chmap(struct priv *p)
{
    uint8_t labels[MP_NUM_CHANNELS];
    uint32_t n = orender_channel_layout(p->renderer, labels,
                                        MP_NUM_CHANNELS);
    if (n == 0 || n > MP_NUM_CHANNELS)
        return false;

    mp_chmap_from_str(&p->chmap, bstr0("empty")); /* reset */
    p->chmap.num = n;
    bool ok = true;
    for (uint32_t i = 0; i < n; i++) {
        int sp = label_to_mp_speaker(labels[i]);
        if (sp == MP_SPEAKER_ID_NA)
            ok = false;
        p->chmap.speaker[i] = sp;
    }
    return ok;
}

static int init(struct dec_audio *da, const char *decoder)
{
    /* MPV-API: codec id field path; only TrueHD is ours. */
    if (da->codec->codec_id != AV_CODEC_ID_TRUEHD)
        return 0;

    struct priv *p = talloc_zero(NULL, struct priv);
    da->priv = p;
    p->log = da->log;
    p->sample_rate = da->codec->samplerate;

    OrenderConfig cfg = {
        .sample_rate        = p->sample_rate,
        .config_yaml_path   = ORENDER_DEFAULT_CONFIG_PATH,
        .speaker_layout_path = NULL,
        .bridge_path        = ORENDER_DEFAULT_BRIDGE_PATH,
        .osc_enabled        = 0,
        .osc_port_in        = 0,
        .osc_port_out       = 0,
        .osc_bind           = "127.0.0.1",
        .osc_host           = "127.0.0.1",
    };

    p->renderer = orender_create(&cfg);
    if (!p->renderer) {
        MP_ERR(p, "orender_create failed (bridge=%s)\n", cfg.bridge_path);
        return 0;
    }

    p->channels = orender_channel_count(p->renderer);
    /* is_spatial() is only meaningful after the first packet, so the
     * Atmos-vs-plain decision happens in decode_packet(). */
    return 1;
}

static int decode_packet(struct dec_audio *da, struct demux_packet *pkt,
                         struct mp_aframe **out)
{
    struct priv *p = da->priv;
    *out = NULL;

    if (!pkt)
        return AD_EOF;

    const size_t max_frames = 4096;
    const size_t capacity = max_frames * (size_t)p->channels;
    float *samples = talloc_array(NULL, float, capacity);

    size_t n_frames = 0;
    uint32_t n_channels = 0;
    int64_t out_pts_us = 0;
    /* MPV-API: pkt->pts is in seconds (double); FFI wants µs. */
    int64_t pts_us = (int64_t)(pkt->pts * 1e6);

    int ret = orender_process(p->renderer, pkt->buffer, pkt->len, pts_us,
                              samples, capacity,
                              &n_frames, &n_channels, &out_pts_us);
    if (ret < 0) {
        MP_ERR(p, "orender_process error %d\n", ret);
        talloc_free(samples);
        return AD_ERR;
    }
    if (ret > 0) {
        /* Output buffer too small — should not happen with max_frames, but be
         * explicit so a future smaller cap is caught. */
        MP_WARN(p, "orender_process: output buffer too small\n");
        talloc_free(samples);
        return AD_OK;
    }

    /* Resolve Atmos-vs-plain on the first decoded packet. */
    if (!p->checked_spatial) {
        p->checked_spatial = true;
        if (orender_is_spatial(p->renderer) != 1) {
            MP_VERBOSE(p, "stream is not Atmos; falling back (use --ad=orender,lavc)\n");
            talloc_free(samples);
            return AD_ERR;   /* triggers next decoder in the --ad list */
        }
        if (!build_chmap(p))
            MP_WARN(p, "output layout has speakers with no mpv mapping\n");
    }

    if (n_frames == 0) {
        talloc_free(samples);
        return AD_OK;   /* need more data */
    }

    *out = mp_aframe_create();
    mp_aframe_set_format(*out, AF_FORMAT_FLOAT);   /* interleaved float32 */
    mp_aframe_set_rate(*out, p->sample_rate);
    mp_aframe_set_chmap(*out, &p->chmap);
    mp_aframe_set_size(*out, n_frames);
    mp_aframe_set_pts(*out, out_pts_us / 1e6);

    /* AF_FORMAT_FLOAT is interleaved → a single plane. */
    uint8_t **planes = mp_aframe_get_data_rw(*out);
    if (planes && planes[0]) {
        memcpy(planes[0], samples,
               n_frames * (size_t)n_channels * sizeof(float));
    } else {
        MP_ERR(p, "mp_aframe_get_data_rw returned no writable plane\n");
        TA_FREEP(out);
        talloc_free(samples);
        return AD_ERR;
    }

    talloc_free(samples);
    return AD_OK;
}

static int control(struct dec_audio *da, int cmd, void *arg)
{
    struct priv *p = da->priv;
    switch (cmd) {
    case ADCTRL_RESET:
        orender_reset(p->renderer);
        p->checked_spatial = false;  /* re-resolve after a seek/discontinuity */
        return CONTROL_TRUE;
    }
    return CONTROL_UNKNOWN;
}

static void uninit(struct dec_audio *da)
{
    struct priv *p = da->priv;
    if (p && p->renderer)
        orender_destroy(p->renderer);
}

/* MPV-API: some mpv versions enumerate decoders via add_decoders() into a
 * mp_decoder_list instead of (or in addition to) the static ad_drivers[] array.
 * Provide it so registration patch 0002 can rely on either path. */
static void add_decoders(struct mp_decoder_list *list)
{
    mp_add_decoder(list, "orender", "truehd",
                   "TrueHD/Atmos via liborender (VBAP object rendering)");
}

const struct ad_functions ad_orender = {
    .name = "orender",
    .add_decoders = add_decoders,
    .init = init,
    .control = control,
    .decode_packet = decode_packet,
    .uninit = uninit,
};

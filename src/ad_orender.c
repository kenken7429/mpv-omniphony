/*
 * ad_orender.c — mpv audio decoder that renders spatial audio through liborender.
 *
 * Companion to ad_lavc/ad_spdif: when the user opts in with `--ad=orender` on a
 * supported stream, decode + VBAP-render the spatial objects to N-channel
 * float PCM via liborender (orender_*), instead of letting FFmpeg downmix.
 *
 * Modeled on ad_spdif.c (a non-lavc mp_filter decoder). liborender does the
 * decode (via a runtime bridge plugin) and the spatial render; this file only
 * shuttles packets in and aframes out through the filter pin protocol.
 *
 * Phase 4: opt-in only (so default playback is untouched). The decoder
 * bridge and speaker layout come from the shared omniphony config YAML
 * (render.bridge_path) — the SAME config the orender CLI + studio use
 * (~/.config/omniphony/config.yaml), resolved by liborender when the config
 * path is NULL. The `--ad-orender-*` options, the is_spatial→ad_lavc fallback,
 * and custom chmaps are Phase 5.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "mpv_talloc.h"
#include "audio/aframe.h"
#include "audio/chmap.h"
#include "audio/format.h"
#include "common/codecs.h"
#include "common/msg.h"
#include "demux/packet.h"
#include "demux/stheader.h"
#include "filters/f_decoder_wrapper.h"
#include "filters/filter_internal.h"
#include "options/m_config.h"

#include <orender.h>

/* --ad-orender-* options. All paths/hosts default to empty → passed to
 * liborender as NULL, which then resolves the shared omniphony config
 * (~/.config/omniphony/config.yaml, the same one the CLI + studio use) for the
 * bridge path, speaker layout, and OSC settings. These options only override
 * the config on a per-mpv-invocation basis. */
#define OPT_BASE_STRUCT struct ad_orender_params
struct ad_orender_params {
    char *config_path;          // override render config YAML (else shared default)
    char *bridge_path;          // override render.bridge_path
    bool osc;                   // force OSC on (else follows config render.osc)
    int osc_port;               // outgoing/monitoring port (0 = config/default)
    int osc_rx_port;            // incoming control port  (0 = config/default 9000)
    char *osc_bind;             // listener bind address (else config/default)
    char *osc_monitor_target;   // monitoring host (else config/default)
};

const struct m_sub_options ad_orender_conf = {
    .opts = (const m_option_t[]) {
        {"config", OPT_STRING(config_path), .flags = M_OPT_FILE},
        {"bridge-path", OPT_STRING(bridge_path), .flags = M_OPT_FILE},
        {"osc", OPT_BOOL(osc)},
        {"osc-port", OPT_INT(osc_port), M_RANGE(0, 65535)},
        {"osc-rx-port", OPT_INT(osc_rx_port), M_RANGE(0, 65535)},
        {"osc-bind", OPT_STRING(osc_bind)},
        {"osc-monitor-target", OPT_STRING(osc_monitor_target)},
        {0}
    },
    .size = sizeof(struct ad_orender_params),
    .defaults = &(const struct ad_orender_params){
        .osc = false,
        .osc_port = 0,
        .osc_rx_port = 0,
    },
};

/* An empty option string means "unset" → pass NULL to the FFI. */
static const char *nz(const char *s) { return (s && s[0]) ? s : NULL; }

/* liborender channel labels — mirror bridge_api::RChannelLabel. cbindgen runs
 * with parse_deps=false, so orender.h does not emit this enum; keep in sync. */
enum {
    OR_L = 0, OR_R = 1, OR_C = 2, OR_LFE = 3, OR_LS = 4, OR_RS = 5,
    OR_TFL = 6, OR_TFR = 7, OR_TSL = 8, OR_TSR = 9, OR_TBL = 10, OR_TBR = 11,
    OR_LSC = 12, OR_RSC = 13, OR_LB = 14, OR_RB = 15, OR_CB = 16, OR_TC = 17,
    OR_LSD = 18, OR_RSD = 19, OR_LW = 20, OR_RW = 21, OR_TFC = 22, OR_LFE2 = 23,
    OR_UNKNOWN = 255,
};

struct priv {
    struct mp_log *log;
    struct mp_codec_params *codec;
    OrenderRenderer *renderer;
    int sample_rate;
    int channels;
    struct mp_chmap chmap;
    bool checked_spatial;
    struct mp_decoder public;
};

/* Map a liborender label to an mpv speaker id. The 7.1.4 default maps exactly.
 * mpv's chmap has no top-side L/R, so those degrade to NA (Phase 5: custom
 * order). */
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
    default:      return MP_SPEAKER_ID_NA;  /* incl. TSL/TSR/LSD/RSD */
    }
}

/* Build p->chmap from the renderer's output layout. Returns false if any
 * speaker had no mpv mapping (caller still proceeds; positions are NA). */
static bool build_chmap(struct priv *p)
{
    uint8_t labels[MP_NUM_CHANNELS];
    uint32_t n = orender_channel_layout(p->renderer, labels, MP_NUM_CHANNELS);
    if (n == 0 || n > MP_NUM_CHANNELS) {
        p->chmap = (struct mp_chmap){0};
        return false;
    }
    p->chmap = (struct mp_chmap){0};
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

static void ad_orender_destroy(struct mp_filter *da)
{
    struct priv *p = da->priv;
    if (p->renderer) {
        orender_destroy(p->renderer);
        p->renderer = NULL;
    }
}

static void ad_orender_reset(struct mp_filter *da)
{
    struct priv *p = da->priv;
    if (p->renderer)
        orender_reset(p->renderer);
    p->checked_spatial = false;
}

static void ad_orender_process(struct mp_filter *da)
{
    struct priv *p = da->priv;

    if (!mp_pin_can_transfer_data(da->ppins[1], da->ppins[0]))
        return;

    struct mp_frame inframe = mp_pin_out_read(da->ppins[0]);
    if (inframe.type == MP_FRAME_EOF) {
        mp_pin_in_write(da->ppins[1], inframe);
        return;
    } else if (inframe.type != MP_FRAME_PACKET) {
        if (inframe.type) {
            MP_ERR(da, "unknown frame type\n");
            mp_filter_internal_mark_failed(da);
        }
        return;
    }

    struct demux_packet *mpkt = inframe.data;
    struct mp_aframe *out = NULL;
    bool failed = false;
    double pts = mpkt->pts;   /* demuxer timestamp; drives A/V sync (see below) */

    int ch = p->channels > 0 ? p->channels : 1;
    size_t capacity = (size_t)4096 * (size_t)ch;
    float *samples = talloc_array(NULL, float, capacity);

    size_t n_frames = 0;
    uint32_t n_ch = 0;
    int64_t out_pts_us = 0;
    int64_t pts_us = mpkt->pts == MP_NOPTS_VALUE ? 0 : (int64_t)(mpkt->pts * 1e6);

    int ret = orender_process(p->renderer, mpkt->buffer, mpkt->len, pts_us,
                              samples, capacity,
                              &n_frames, &n_ch, &out_pts_us);
    if (ret < 0) {
        MP_ERR(da, "orender_process error %d\n", ret);
        failed = true;
        goto done;
    }
    if (ret > 0) {
        MP_WARN(da, "orender output buffer too small; dropping packet\n");
        goto done;
    }

    /* Resolve spatial-vs-plain + the output chmap on the first decoded packet. */
    if (!p->checked_spatial) {
        p->checked_spatial = true;
        if (orender_is_spatial(p->renderer) != 1) {
            MP_WARN(da, "no spatial objects detected; rendering the bed only "
                        "(decode this track without --ad=orender for the "
                        "standard downmix)\n");
        }
        if (!build_chmap(p))
            MP_WARN(da, "output layout has speakers with no mpv mapping\n");
    }

    if (n_frames == 0)
        goto done;   /* packet consumed; no output yet (need more data) */

    out = mp_aframe_create();
    mp_aframe_set_format(out, AF_FORMAT_FLOAT);   /* interleaved float32 */
    mp_aframe_set_rate(out, p->sample_rate);
    mp_aframe_set_chmap(out, &p->chmap);
    /* Timestamp from the demuxer packet PTS (like ad_spdif), NOT the engine's
     * internal sample clock (out_pts_us): that clock resets to 0 on seek
     * (orender_reset), which puts the audio in the past so mpv drops every
     * frame after a seek — video keeps playing but audio goes silent while the
     * renderer is still producing samples. The packet PTS tracks seeks. */
    mp_aframe_set_pts(out, pts);

    /* format + rate + chmap must be set before allocating the data buffer. */
    if (!mp_aframe_alloc_data(out, n_frames)) {
        MP_ERR(da, "failed to allocate output frame (%zu frames, %u ch)\n",
               n_frames, n_ch);
        TA_FREEP(&out);
        failed = true;
        goto done;
    }

    uint8_t **data = mp_aframe_get_data_rw(out);
    if (!data || !data[0]) {
        MP_ERR(da, "no writable output plane\n");
        TA_FREEP(&out);
        failed = true;
        goto done;
    }
    memcpy(data[0], samples, n_frames * (size_t)n_ch * sizeof(float));

done:
    talloc_free(samples);
    talloc_free(mpkt);
    if (out) {
        mp_pin_in_write(da->ppins[1], MAKE_FRAME(MP_FRAME_AUDIO, out));
    } else if (failed) {
        mp_filter_internal_mark_failed(da);
    }
}

static const struct mp_filter_info ad_orender_filter = {
    .name = "ad_orender",
    .priv_size = sizeof(struct priv),
    .process = ad_orender_process,
    .reset = ad_orender_reset,
    .destroy = ad_orender_destroy,
};

static struct mp_decoder *create(struct mp_filter *parent,
                                 struct mp_codec_params *codec,
                                 const char *decoder)
{
    if (!codec->codec ||
        (strcmp(codec->codec, "truehd") != 0 && strcmp(codec->codec, "eac3") != 0))
        return NULL;
    bool is_eac3 = strcmp(codec->codec, "eac3") == 0;

    struct mp_filter *da = mp_filter_create(parent, &ad_orender_filter);
    if (!da)
        return NULL;

    mp_filter_add_pin(da, MP_PIN_IN, "in");
    mp_filter_add_pin(da, MP_PIN_OUT, "out");

    da->log = mp_log_new(da, parent->log, NULL);

    struct priv *p = da->priv;
    p->log = da->log;
    p->codec = codec;
    p->sample_rate = codec->samplerate;
    p->public.f = da;

    struct ad_orender_params *opts =
        mp_get_config_group(da, da->global, &ad_orender_conf);

    OrenderConfig cfg = {
        .sample_rate         = p->sample_rate,
        /* NULL → liborender resolves the shared omniphony config; these only
         * override it for this mpv invocation. OSC: --ad-orender-osc forces it
         * on, otherwise osc_enabled=0 lets liborender follow render.osc. Ports/
         * host/bind 0/NULL fall back to the config then the built-in defaults. */
        .config_yaml_path    = nz(opts->config_path),
        .speaker_layout_path = NULL,
        .bridge_path         = nz(opts->bridge_path),
        /* Tell the bridge which codec the raw access units carry: its raw
         * transport has no data-type byte to distinguish the supported
         * codecs from each other. */
        .codec               = codec->codec,
        .osc_enabled         = opts->osc ? 1 : 0,
        .osc_port_in         = (uint16_t)opts->osc_rx_port,
        .osc_port_out        = (uint16_t)opts->osc_port,
        .osc_bind            = nz(opts->osc_bind),
        .osc_host            = nz(opts->osc_monitor_target),
    };

    p->renderer = orender_create(&cfg);
    if (!p->renderer) {
        MP_ERR(da, "orender_create failed — set render.bridge_path in your "
                   "omniphony config (~/.config/omniphony/config.yaml); see "
                   "stderr for the liborender error\n");
        talloc_free(da);
        return NULL;
    }

    p->channels = orender_channel_count(p->renderer);
    codec->codec_desc = is_eac3 ? "eac3 (orender, spatial)"
                                : "truehd (orender, spatial)";

    return &p->public;
}

static void add_decoders(struct mp_decoder_list *list)
{
    mp_add_decoder(list, "truehd", "orender",
                   "Spatial audio via liborender (VBAP object rendering)");
    mp_add_decoder(list, "eac3", "orender",
                   "Spatial audio via liborender (VBAP object rendering)");
}

const struct mp_decoder_fns ad_orender = {
    .create = create,
    .add_decoders = add_decoders,
};

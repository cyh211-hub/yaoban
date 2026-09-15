// GPL-3.0. Generate synthetic 440 Hz CELT wideband frames using the official API.
#include "Fixtures.h"
#include <math.h>
#include <stddef.h>

OpusEncoder *yb_voice_test_encoder(void) {
    int error = 0;
    OpusEncoder *encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error);
    if (!encoder) return NULL;
    if (error || opus_encoder_ctl(encoder, OPUS_SET_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND)) ||
        opus_encoder_ctl(encoder, OPUS_SET_BITRATE(32000)) ||
        opus_encoder_ctl(encoder, OPUS_SET_VBR(0))) {
        opus_encoder_destroy(encoder);
        return NULL;
    }
    return encoder;
}

int yb_voice_test_frame(OpusEncoder *encoder, int frame, unsigned char *output, int capacity) {
    if (!encoder || !output || capacity < 94 || frame < 0 || frame > 10000) return OPUS_BAD_ARG;
    opus_int16 samples[960];
    for (int i = 0; i < 960; ++i)
        samples[i] = (opus_int16)(8000 * sin(2 * 3.141592653589793 * 440 * (frame * 960.0 + i) / 48000));
    return opus_encode(encoder, samples, 960, output, capacity);
}

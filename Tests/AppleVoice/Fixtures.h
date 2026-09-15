// GPL-3.0. Test-only synthetic signal; never opens a microphone or output device.
#include <opus.h>
OpusEncoder *yb_voice_test_encoder(void);
int yb_voice_test_frame(OpusEncoder *encoder, int frame, unsigned char *output, int capacity);

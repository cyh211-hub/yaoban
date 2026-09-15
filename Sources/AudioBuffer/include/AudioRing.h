#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct MiAudioRing MiAudioRing;
MiAudioRing *MiAudioRingCreate(uint32_t capacity);
void MiAudioRingDestroy(MiAudioRing *ring);
// Reset only while the output unit is stopped.
void MiAudioRingReset(MiAudioRing *ring);
uint32_t MiAudioRingWrite(MiAudioRing *ring, const float *samples, uint32_t frames);
// Real-time callback: no allocation, locks, logging or system calls.
uint32_t MiAudioRingRender(MiAudioRing *ring, float *interleaved, uint32_t frames, uint32_t channels);
uint32_t MiAudioRingAvailable(MiAudioRing *ring);

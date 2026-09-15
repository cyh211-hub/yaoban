// GPL-3.0. Single producer / single consumer mono float ring.
#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MiAudioRing {
    _Atomic uint32_t read;
    _Atomic uint32_t write;
    uint32_t capacity;
    float samples[];
};
MiAudioRing *MiAudioRingCreate(uint32_t capacity) {
    if (!capacity || capacity > 1048576) return NULL;
    MiAudioRing *r = calloc(1, sizeof(*r) + capacity * sizeof(float));
    if (r) { r->capacity = capacity; atomic_init(&r->read, 0); atomic_init(&r->write, 0); }
    return r;
}
void MiAudioRingDestroy(MiAudioRing *r) { free(r); }
void MiAudioRingReset(MiAudioRing *r) { atomic_store(&r->read, 0); atomic_store(&r->write, 0); }
uint32_t MiAudioRingWrite(MiAudioRing *r, const float *input, uint32_t frames) {
    uint32_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    uint32_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
    uint32_t count = r->capacity - (w - rd);
    if (count > frames) count = frames;
    for (uint32_t i = 0; i < count; ++i) r->samples[(w + i) % r->capacity] = input[i];
    atomic_store_explicit(&r->write, w + count, memory_order_release);
    return count;
}
uint32_t MiAudioRingRender(MiAudioRing *r, float *output, uint32_t frames, uint32_t channels) {
    uint32_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    uint32_t w = atomic_load_explicit(&r->write, memory_order_acquire);
    uint32_t count = w - rd;
    if (count > frames) count = frames;
    for (uint32_t i = 0; i < count; ++i) {
        float sample = r->samples[(rd + i) % r->capacity];
        for (uint32_t c = 0; c < channels; ++c) output[i * channels + c] = sample;
    }
    memset(output + (size_t)count * channels, 0, (size_t)(frames - count) * channels * sizeof(float));
    atomic_store_explicit(&r->read, rd + count, memory_order_release);
    return count;
}
uint32_t MiAudioRingAvailable(MiAudioRing *r) {
    // The caller is the producer; only the consumer can advance read here.
    uint32_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
    return atomic_load_explicit(&r->write, memory_order_relaxed) - rd;
}

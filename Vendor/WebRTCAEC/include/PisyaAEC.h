#pragma once
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PisyaEcho PisyaEcho;
PisyaEcho *PisyaEchoCreate(void);
void PisyaEchoDestroy(PisyaEcho *state);
/* Mono, 16 kHz, 160 float samples in [-1,1]. No network or device access. */
int PisyaEchoProcess(PisyaEcho *state, const float *microphone, const float *playback, float *output);
#ifdef __cplusplus
}
#endif

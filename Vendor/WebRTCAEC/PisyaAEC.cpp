#include "include/PisyaAEC.h"
#include "api/audio/audio_processing.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include <algorithm>

class NearSpeechEchoFactory final : public webrtc::EchoControlFactory {
 public:
    std::unique_ptr<webrtc::EchoControl> Create(int rate, int render, int capture) override {
        webrtc::EchoCanceller3Config config;
        // Allow the measured linear filter improvement to protect quiet near speech.
        // The stock caps (4 low / 1.5 high) overestimated residual echo in double-talk.
        config.erle.max_l = 100.f;
        config.erle.max_h = 100.f;
        return std::make_unique<webrtc::EchoCanceller3>(config, std::nullopt, rate, render, capture);
    }
};

struct PisyaEcho {
    rtc::scoped_refptr<webrtc::AudioProcessing> processor;
    webrtc::StreamConfig format{16000, 1};
};
extern "C" PisyaEcho *PisyaEchoCreate() {
    auto *state = new PisyaEcho;
    state->processor = webrtc::AudioProcessingBuilder().SetEchoControlFactory(std::make_unique<NearSpeechEchoFactory>()).Create();
    if (!state->processor) { delete state; return nullptr; }
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.echo_canceller.enforce_high_pass_filtering = false;
    config.high_pass_filter.enabled = false;
    config.noise_suppression.enabled = false;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    state->processor->ApplyConfig(config);
    return state;
}
extern "C" void PisyaEchoDestroy(PisyaEcho *state) { delete state; }
extern "C" int PisyaEchoProcess(PisyaEcho *state, const float *microphone, const float *playback, float *output) {
    if (!state) return -1;
    float render[160];
    std::copy(playback, playback + 160, render);
    const float *renderInput[] = {render}; float *renderOutput[] = {render};
    int result = state->processor->ProcessReverseStream(renderInput, state->format, state->format, renderOutput);
    if (result) return result;
    state->processor->set_stream_delay_ms(100);
    const float *captureInput[] = {microphone}; float *captureOutput[] = {output};
    result = state->processor->ProcessStream(captureInput, state->format, state->format, captureOutput);
    return result;
}

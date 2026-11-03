# WebRTC audio processing

Static audio-only WebRTC AEC3 module, version 2.1, with Abseil 20240722.0. The original source URL, SHA-256 and build-tool versions are pinned in `versions.json`. The application performs no network operations through this module.

`PisyaAEC.cpp` exposes one mono 16 kHz, 10 ms float-frame function through `include/PisyaAEC.h`. Automatic gain control, general noise suppression and high-pass filtering are disabled. AEC3 receives the explicit playback reference supplied by the application. The ERLE estimator's upper caps allow the measured adaptive-filter improvement to protect quiet near speech; the lower bound remains unchanged. Processing failures are explicit errors. The measured block-framing latency is 128 samples and is compensated when writing the derivative audio. The reference lookahead is primed at each file boundary before output begins.

The committed static archive targets Apple Silicon and macOS 15 or later. Rebuild on an Apple Silicon Mac with Xcode Command Line Tools:

```sh
python3 Vendor/WebRTCAEC/rebuild.py --work-dir build/webrtc-aec3-vendor
```

The build downloads the pinned upstream source and build tools. Application runtime uses only the bundled static code. WebRTC BSD and Abseil Apache licenses are included beside the archive and copied into the application bundle.

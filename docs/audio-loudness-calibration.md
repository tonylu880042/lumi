# Recorded voice loudness calibration

Status: offline mastering completed on 2026-09-17; physical Live-device A/B
acceptance remains pending.

The eight bundled Marin recordings were consistently quieter than the Live
speech path. The approved trial target is -18.0 LUFS integrated loudness with
a maximum true peak of -1.5 dBTP and ±0.5 LU measurement tolerance. This is an
offline asset calibration; it does not claim that the recordings will match
the measured output level of Live on an iPhone until the physical A/B check is
complete. The existing Live gain of 2.0 is unchanged.

## Source preservation and method

The pre-calibration WAVs are preserved in
[`tools/AudioCalibration/originals/`](../tools/AudioCalibration/originals/),
with SHA-256 hashes, frame counts, and PCM format metadata in
[`manifest.json`](../tools/AudioCalibration/originals/manifest.json). The
bundle derivatives are generated only from those immutable sources, so running
the normalizer again cannot compound a previous gain change.

The normalizer uses ffmpeg's measured two-pass `loudnorm` filter, then writes
PCM signed 16-bit little-endian WAV at 24 kHz, mono. It does not add fades or
silence and does not change words, voice, sample rate, or frame count. Every
temporary output is measured and checked before it is copied into the bundle.

## Measurements

| File | Frames | Duration | Before LUFS | Before TP | After LUFS | After TP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 01-welcome.wav | 108,000 | 4.50 s | -22.04 | -3.34 | -17.99 | -1.51 |
| 02-welcome.wav | 90,000 | 3.75 s | -22.74 | -7.93 | -18.00 | -3.19 |
| 03-welcome.wav | 68,400 | 2.85 s | -21.50 | -7.06 | -18.00 | -3.55 |
| 04-returning.wav | 61,200 | 2.55 s | -21.24 | -8.10 | -18.00 | -4.88 |
| 05-returning.wav | 73,200 | 3.05 s | -21.43 | -7.53 | -18.02 | -4.10 |
| 06-returning.wav | 80,400 | 3.35 s | -22.20 | -5.26 | -18.24 | -1.53 |
| 07-goodbye.wav | 85,200 | 3.55 s | -23.47 | -7.98 | -18.02 | -2.51 |
| 08-goodbye.wav | 66,000 | 2.75 s | -23.09 | -8.19 | -18.00 | -3.14 |

All eight post-encode files pass the target policy, remain PCM16 mono 24 kHz,
and retain their exact source frame counts and durations.

## Reproduction and verification

From the repository root, with ffmpeg and ffprobe available on `PATH`:

```sh
python3 tools/AudioCalibration/audio_calibration.py audit \
  --assets Sources/LumiInfrastructure/Resources/RecordedVoice \
  --check \
  --json-output /private/tmp/lumi-recorded-loudness-audit-after.json

python3 tools/AudioCalibration/audio_calibration.py normalize \
  --originals tools/AudioCalibration/originals \
  --assets Sources/LumiInfrastructure/Resources/RecordedVoice \
  --manifest tools/AudioCalibration/originals/manifest.json \
  --json-output /private/tmp/lumi-after-audio-leveling.json

python3 tools/AudioCalibration/test_audio_calibration.py
```

The `normalize` command verifies the source manifest and stages all outputs in
a temporary directory. It copies into the resource bundle only after every
output passes loudness, true-peak, codec, channel, sample-rate, bit-depth, and
frame-count checks.

## Physical acceptance boundary

Manual iPhone A/B playback of a calibrated clip and comparable Live speech is
still pending. Check perceived level, clipping, route changes, playback
handoff, microphone echo, and Taiwanese Mandarin intelligibility in the Live
composition.

The bundled WebRTC header
`.build/artifacts/webrtc/WebRTC/WebRTC.xcframework/ios-arm64/WebRTC.framework/Headers/RTCAudioSession.h`
documents that an active VoIP audio unit can cut off an AVPlayer or play it at
a reduced volume, and exposes `useManualAudio`/`isAudioEnabled` for that
lifecycle. That is a possible device-side explanation for a remaining
mismatch. This calibration does not change the audio session, AEC, routing, or
Live gain; those changes require measured device evidence first.

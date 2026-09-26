# Offline HLS and PiP audio fixtures

`pip-audio.mp4` combines the existing synthetic 20-second video fixture with a
quiet 440 Hz sine wave (AAC stereo, 48 kHz). It contains no third-party media.
`offline-hls/` is the local HLS package produced by `HlsDownloadManager` from
this clip served by the loopback HTTP fixture test. Its five MPEG-TS segments
contain the same video and audio; no remote URLs or job metadata are bundled.
The native PiP test opens this package with VLC, exercises its real AudioUnit,
and verifies volume continuity. The earlier `video.mp4` fixture had no audio.

From the repository root, regenerate with FFmpeg:

```sh
ffmpeg -i packages/vlc_player/example/assets/format_fixtures/video_lifecycle.mp4 \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=20' \
  -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a 96k -ac 2 \
  -af volume=0.2 -shortest -movflags +faststart \
  ios/RunnerTests/Fixtures/pip-audio.mp4
```

Generate the served HLS source with:

```sh
mkdir -p /tmp/skystream-hls-fixture
ffmpeg -i ios/RunnerTests/Fixtures/pip-audio.mp4 -map 0:v -map 0:a -c copy \
  -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename /tmp/skystream-hls-fixture/segment%03d.ts \
  /tmp/skystream-hls-fixture/index.m3u8
HLS_FIXTURE_DIR=/tmp/skystream-hls-fixture HLS_OUTPUT_DIR=/tmp/skystream-hls-output \
  HLS_OUTPUT_FILENAME='S1-E13 13.m3u8' \
  flutter test test/core/services/hls_download_test.dart
```

Copy the output `S1-E13 13.m3u8` and `hls-*.hls/*.ts` into `offline-hls/`,
preserving the hashed asset directory. This exercises episode names with spaces.
Do not copy `job.json`, which records transient download URLs and headers.

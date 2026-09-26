# Maintained iOS fork

This personal fork tracks [akashdh11/skystream](https://github.com/akashdh11/skystream).
`main` now contains the personal iOS fixes. The rollback tag
`ios-v2.7.6+7-rollback` points to `5d804552`, the source of the signed 2.7.6+7
build. The v2.8.0 integration is developed on `update/upstream-v2.8.0` until
validation and device acceptance are complete.

## Branches and local changes

- `main` is the maintained fork, not an unmodified upstream mirror.
- `ios-local-build` and `ios-picture-in-picture` retain the previous work.
- `update/upstream-v2.8.0` merges stable upstream `v2.8.0` (`12fb9a0d`).
- `origin` is `https://github.com/vladislawfox/skystream.git`.
- `upstream` is `https://github.com/akashdh11/skystream.git`.

The changes are kept in separate commits so the portable fixes can be reviewed
independently from personal signing:

1. Apple platforms use URLSession for provider HTTP requests and cached images.
   This fixed an observed UAKino request that returned HTTP 403 through Dart's
   HTTP client and HTTP 200 through URLSession with the same URL and headers.
   Plugin responses retain the final URL and separate `Set-Cookie` values. The
   extension engine continues to own cookie policy. Enabling custom DNS uses
   the existing Dart socket adapter; other platforms keep their existing adapter.
2. The developer Logs screen opens in profile/release builds, which already
   maintain the bounded, redacted log buffer.
3. The iOS project uses the personal signing team and `com.vlad.skystream`
   bundle identifier. A different developer must choose their own team and
   bundle identifier in Xcode. Certificates, private keys, provisioning
   profiles, service credentials and device identifiers are not included.
4. Movies returned without an episode list can be played from their details
   page. The Play button accepts a resolved movie, and playback resolves its
   page URL when no explicit playback entry exists. Provider-supplied entries
   and series episode selection retain their existing behavior.
5. iOS uses VLC's existing decoded frames for Apple's Picture in Picture.
   Going to the Home Screen can continue playback in the system window, and
   the player also offers a PiP button. Native code owns background transitions,
   playback controls and interruption handling without reopening the stream.
   Background audio is enabled for PiP. If PiP cannot start, playback pauses
   until the app returns; a user pause or window close stays paused.

Ukrainian providers are distributed separately in
[skystream-ukrainian](https://github.com/vladislawfox/skystream-ukrainian).
Their implementations are not embedded in the app.

## Updating from upstream

Start with a clean working tree and tag the accepted build before updating.
Create an integration branch from the maintained `main`, then merge a reviewed
stable upstream tag without rewriting history:

```sh
git fetch origin
git fetch upstream --tags
git switch main
git merge --ff-only origin/main
git switch -c update/upstream-v2.8.0
git merge --no-ff v2.8.0
```

Resolve conflicts while keeping the fork's network, PiP, download and signing
changes. Run the checks below, build with an increasing local build number and
the same bundle identity, then install over the existing app. Push the candidate
branch for review; fast-forward `main` only after accepting the updated build.
Do not reset or force-push shared branches.

To restore the previous app, reinstall the locally retained signed 2.7.6+7 app,
or build a fresh checkout of `ios-v2.7.6+7-rollback` using Flutter 3.47.1. The tag
preserves source; a development-signed app may need re-signing after its profile
expires. Installing an app does not change Git branches.

## Build and tests

The v2.8.0 candidate uses upstream's Flutter `3.47.5` / Dart `3.13.4`, Xcode
`27.0` and CocoaPods `1.17.0` on Apple Silicon. The rollback build used Flutter
`3.47.1` / Dart `3.13.1`. From the repository root:

```sh
flutter pub get --enforce-lockfile
flutter gen-l10n
dart run build_runner build
flutter build ios --profile --no-pub
```

Builds use Xcode's normal development signing. Upstream ignores `ios/Podfile.lock`;
retain the lockfile locally and use `pod install`, not `pod update`, for repeat
builds of the same revision. No private API credentials are required for a base
build; features requiring service credentials need their own configuration.
Run `pod install` from the `ios` directory: Flutter's pod helper uses that
working directory to distinguish Swift Package Manager plugins from CocoaPods.

The Apple transport tests use an actual local HTTP server and native URLSession.
The standalone macOS Flutter test runner needs the Cupertino plugin's native
module loaded explicitly; normal app builds link it automatically through Xcode.
On macOS, after `flutter pub get`:

```sh
skystream_test_dir="$(mktemp -d)"
skystream_pub_cache="${PUB_CACHE:-$HOME/.pub-cache}"
xcrun clang -dynamiclib -fobjc-arc -framework Foundation \
  "$skystream_pub_cache/hosted/pub.dev/cupertino_http-2.4.0/darwin/cupertino_http/Sources/cupertino_http/native_cupertino_bindings.m" \
  -o "$skystream_test_dir/libcupertino_http.dylib"
SKYSTREAM_CUPERTINO_LIBRARY="$skystream_test_dir/libcupertino_http.dylib" \
  flutter test test/core/network test/core/extensions/engine
```

Without `SKYSTREAM_CUPERTINO_LIBRARY`, the seven native transport tests are
skipped; that does not validate URLSession. The native source path above matches
the committed lockfile and must be reviewed if that dependency changes.

## Verification recorded on 2026-09-17

- All 55 network/plugin-engine tests passed, including seven native transport
  cases: POST bytes and Referer, redirects/final URL, separate clearance cookies
  scoped to the final host, disabled automatic cookie sharing, custom DNS
  selection, cancellation and response size limits.
- Targeted static analysis passed. A signed profile build succeeded, its code
  signature verified, and it was installed and launched on the personal iPhone.
- Live provider checks returned HTTP 200 for details, HLS manifests, subtitles
  and posters. The user subsequently confirmed the updated app works on iPhone.

These checks describe that revision and environment. They do not establish
compatibility with every provider or guarantee future site behavior.

The movie Play regression was reproduced with failing button-tap and autoplay
tests, then fixed. All 40 details-screen tests pass (`flutter test
test/features/details`), including navigation through the real controller and
playback launcher for movies with null/empty episode lists, an explicit movie
entry, and a selected series episode. Tests also retain disabled Play while
details are unavailable or a series has no episodes. Targeted analysis is clean.

## iOS Picture in Picture

Start a movie or episode, then return to the Home Screen. Automatic entry uses
iOS's **Settings > General > Picture in Picture > Start PiP Automatically**
preference. The player's PiP button can also start the system window; its
visibility is configurable in the player control settings.

The app selects `VlcDarwinRenderer.sampleBuffer` on iOS. Its visible
`AVSampleBufferDisplayLayer` is also the AVKit content source, using the same
VLC decoder, stream, audio/subtitle selection and position. Native code controls
background continuation while Dart retains the original player route. The
existing renderers remain available in the bundled package, and other platforms
retain their defaults. The app's minimum iOS version remains 15.6.

Focused checks for this path:

```sh
flutter test test/features/player/player_platform_service_test.dart \
  test/features/player/pip_engine_continuity_test.dart \
  test/features/settings/settings_dialogs_test.dart
(cd packages/vlc_player && flutter test test/vlc_darwin_renderer_test.dart \
  test/vlc_android_renderer_test.dart test/vlc_player_controller_test.dart \
  test/vlc_background_policy_test.dart test/vlc_audio_interruption_test.dart)
swiftc -parse-as-library -module-cache-path /tmp/vlc-pip-module-cache \
  packages/vlc_player/ios/vlc_player/Sources/vlc_player/VlcPictureInPicturePolicy.swift \
  packages/vlc_player/ios/Tests/VlcPictureInPicturePolicyTests.swift \
  -o /tmp/vlc-pip-policy-tests
/tmp/vlc-pip-policy-tests
swiftc -parse-as-library -module-cache-path /tmp/vlc-padding-module-cache \
  packages/vlc_player/ios/vlc_player/Sources/vlc_player/VlcSampleBufferPadding.swift \
  packages/vlc_player/ios/Tests/VlcSampleBufferPaddingTests.swift \
  -o /tmp/vlc-padding-tests
/tmp/vlc-padding-tests
```

On 2026-09-19, these passed: 71 app tests, 121 package tests, and 54 native
policy/frame/geometry checks. Targeted Dart analysis passed. `RunnerTests` also
contains device tests for the visible sample-buffer layer, timebase, clean
aperture, background mode, rejected entry, and real VLC decoding with AVKit
PiP entry/exit. All five tests passed on the personal iPhone 16 Pro on 2026-09-19,
including actual AVKit entry and exit while VLC plays the bundled video fixture.
The first device run exposed an inverted vertical clean-aperture offset: a
320x180 frame in a 320x192 buffer started at row 12 instead of row 0. Correcting
the offset sign made the existing regression pass with the other four tests.

The signed profile build `2.7.6+3` succeeded and passed strict code-signature
verification after the aperture correction. It was installed and launched on
the personal iPhone 16 Pro; the device reported version `2.7.6`, build `3`, and
the app remained running after launch.

A subsequent inline-playback regression measured a 13.1 ms backward jump in
the presentation clock during real VLC playback. Regular progress events now
leave that clock continuous; play/pause changes its rate, and explicit source
changes or seeks discard queued frames before reanchoring. PiP maps the clock
to VLC's media position through the playable time range, preserving progress
and seek controls without rescheduling video that is already queued.
All eight native tests passed on the iPhone after this correction, including
zero backward clock steps during real VLC playback, reset/seek timeline checks
and actual PiP entry/exit. The signed profile build `2.7.6+4` was installed,
launched and confirmed running. The user then retested the original stream and
confirmed that playback is smooth again, without the reported flicker or jumps.

The sample-buffer renderer also extends the visible NV12 edge into the decoder's
right/bottom padding before enqueueing. This prevents scaling from sampling
unwritten chroma outside the clean aperture, which can produce a thin green edge
in both inline playback and PiP. Visible pixels, aperture and presentation timing
are unchanged. The helper modifies only padding and does not copy a full frame.
All 17 standalone CoreVideo checks pass, covering luma/chroma edges, odd sizes,
visible pixel preservation, repeated delivery, full frames and bounded metadata.
The device suite includes a padded NV12 frame through the actual enqueue path.
The signed profile build `2.7.6+5` compiled and passed strict code-signature
verification. All nine native tests passed on the personal iPhone 16 Pro on
2026-09-19, including the NV12 padding regression and actual PiP entry/exit
with zero backward presentation-clock steps. The profile build was installed
and launched. The user subsequently accepted build `2.7.6+5` after checking it
on the iPhone.

### PiP volume and offline episode downloads

The player now keeps its last known volume when libVLC reports an unavailable
audio-output value (`-100`). Previously that value selected 0% in the volume
picker after PiP recreated the controls, and became the starting point for
volume gestures. Touch rails now ignore gestures beginning in system edges,
including the iOS fullscreen edges used for Home and Control Center. Genuine
mute and volume boost values are preserved. Optional native audio diagnostics
can be enabled with `SKYSTREAM_AUDIO_DIAGNOSTICS=1`; they record levels and
route types, never stream URLs or audio samples.

HLS episode downloads now create a local playlist and an adjacent `.hls`
directory containing the selected rendition's segments, audio, initialization
maps and supported encryption keys. Native background tasks fetch these assets
with the source headers. A persisted parent task handles progress, pause,
resume and cancellation, while the root playlist appears only after every
asset completes. Deletion removes both the playlist and its assets. The
confirmation dialog reports an unknown size instead of mistaking the manifest
length for the episode's size. Live and unsupported protected sources produce
an error before downloading.

On 2026-09-27, a synthetic 20-second H.264/AAC episode was served over loopback
HTTP, downloaded through the package manager, and decoded completely with
network protocols disabled. The exact resulting package is the native PiP
fixture. All nine native tests passed on the iPhone 16 Pro: VLC played this
offline HLS package, retained the chosen 60% gain through real PiP entry and
inline restoration, and recorded zero backward presentation-clock steps.
The same checks also passed with a space-containing episode filename and an
ASCII asset-directory name. A separate AES-128 fixture was downloaded and
decoded with network protocols disabled. The related regression run passed
987 app tests and 140 VLC package tests; after final recovery hardening,
all 34 focused download tests passed. Targeted Dart analysis and independent
code review found no remaining issues. The signed profile build `2.7.6+7`
passed strict code-signature verification and was installed and launched on
the iPhone, which reported version `2.7.6`, build `7`.
The original provider episode and the user's normal viewing gestures still
need hands-on confirmation in the installed build.

Automatic Home Screen entry, close versus restore gestures, audio/subtitle sync,
calls/headphone interruptions and sustained playback still require hands-on
verification on the phone; unit tests and compilation alone do not establish
those behaviors.

## v2.8.0 volume integration

Upstream adds system-volume routing on handsets. This fork retains VLC gain on
iOS: flutter_volume_controller 2.0.2 changes AVAudioSession to `.ambient` when
its listener starts, and calls `setActive(false)` when the listener is removed.
PiP removes the Flutter controls while native playback continues, so that
listener cannot own the shared audio session. Hardware buttons still control
iOS system volume; the in-app slider controls VLC gain as in the rollback build.
Other platforms retain upstream volume routing. Supporting an iOS system-volume
slider later requires an observer that does not change session ownership.

### Integration verification, 2026-09-27

The v2.8.0 candidate passed 1897 app tests (six conditional live/golden probes
skipped), 296 VLC package tests, 54 native PiP policy/frame checks and 17 NV12
padding checks. Full Dart analysis found no issues. All nine RunnerTests passed
on the iPhone, including real offline HLS playback and unchanged 60% gain through
PiP entry/exit with zero backward presentation-clock steps. A live UAKino check
through the updated JavaScriptCore worker and Apple URLSession covered home,
search, movie/series details, stream resolution, HLS, subtitles and poster loading.

The signed profile 2.8.0+8 passed strict code-signature verification and was
installed and launched over the existing app. Independent integration review
found no actionable issue. Device acceptance of normal viewing gestures and
longer playback is still pending; `main` and the rollback tag retain 2.7.6+7.

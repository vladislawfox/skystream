# Maintained iOS fork

This personal fork tracks [akashdh11/skystream](https://github.com/akashdh11/skystream).
The installed iPhone build uses `ios-local-build`, based on upstream commit
`71a60612d32c1de2b63b7e99d20444a2c2265a76` (app version `2.7.6`).

## Branches and local changes

- `main` follows upstream `master` without fork-specific commits.
- `ios-local-build` is the default branch and contains the maintained changes.
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

Start with a clean working tree. These commands fast-forward the mirror branch,
then merge upstream changes into the maintained branch without rewriting its
history:

```sh
git fetch upstream
git switch main
git merge --ff-only upstream/master
git push origin main
git switch ios-local-build
git merge main
```

Resolve any conflicts in the network, dependency or signing files, then run the
checks below and build/install on the iPhone. Once verified:

```sh
git push origin ios-local-build
```

If `--ff-only` refuses the update, inspect the branch history before proceeding.
Do not reset or force-push a branch to resolve it. An upstream merge is a source
update; installing the rebuilt app is still required to update the phone.

## Build and tests

The verified setup used Flutter `3.47.1` / Dart `3.13.1`, Xcode `27.0` and
CocoaPods `1.17.0` on Apple Silicon. Follow upstream's Flutter version when
reviewing a later upstream update. From the repository root:

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

Automatic Home Screen entry, close versus restore gestures, audio/subtitle sync,
calls/headphone interruptions and sustained playback still require hands-on
verification on the phone; unit tests and compilation alone do not establish
those behaviors.

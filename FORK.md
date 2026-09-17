# Maintained iOS fork

This personal fork tracks [akashdh11/skystream](https://github.com/akashdh11/skystream).
The installed iPhone build uses `ios-local-build`, based on upstream commit
`71a60612d32c1de2b63b7e99d20444a2c2265a76` (app version `2.7.6+1`).

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

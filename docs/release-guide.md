# Release guide

Status: source may be public. Signing keys stay outside Git.

## Distribution

GitHub Releases are the install and sideload channel:

- signed Android APK
- unsigned iOS IPA for Sideloadly / AltStore
- un-notarized macOS DMG

The app has no self-updater. Installation and updates remain explicit user
actions. Signing material (Android keystore, `key.properties`, Apple
certificates, profiles, and export options) never enters Git.

## GitHub Release automation

`.github/workflows/publish-release-artifacts.yml` runs on a `v*` tag push, or
manually with `workflow_dispatch` and an existing tag. It checks out that tag,
requires the tag to exactly match the `version` in `app/pubspec.yaml`, runs
`flutter analyze` and `flutter test`, and attaches:

- `JFZ-Reader-<tag>-android.apk` — release APK signed with the `jfzreader`
  keystore from GitHub Actions secrets. The job fails if the artifact is
  unsigned or debug-signed.
- `JFZ-Reader-<tag>-ios-unsigned.ipa` — unsigned IPA (`flutter build ios
  --release --no-codesign`). Re-sign with Sideloadly, AltStore, or similar.
  It is not an Ad Hoc or App Store build.
- `JFZ-Reader-<tag>-macos.dmg` — DMG containing the macOS release `.app`.
  Notarization is not performed.

If the GitHub Release for that tag does not exist yet, the publish job creates
it and uploads the assets. Re-running the workflow replaces the assets.

## Android signing

Generate and retain one release key outside the repository. Run `keytool`
interactively so passwords never appear in shell history:

```sh
keytool -genkeypair -v \
  -keystore /absolute/private/path/jfzreader-release.jks \
  -alias jfzreader -keyalg RSA -keysize 4096 -validity 10000
```

For a local build, copy `app/android/key.properties.example` to
`app/android/key.properties` and fill it locally. That file and `*.jks` are
ignored by Git.

GitHub Actions signs the published APK from these repository secrets:

- `JFZREADER_ANDROID_STORE_BASE64` — base64 of the `.jks` (no PEM wrapping)
- `JFZREADER_ANDROID_STORE_PASSWORD`
- `JFZREADER_ANDROID_KEY_ALIAS`
- `JFZREADER_ANDROID_KEY_PASSWORD`

The workflow decodes the keystore to `JFZREADER_ANDROID_STORE_FILE` on the
runner. Gradle already reads those `JFZREADER_ANDROID_*` environment variables.

Build and verify:

```sh
cd app
flutter --no-version-check build apk --release
APKSIGNER="$ANDROID_SDK_ROOT/build-tools/36.0.0/apksigner" \
  scripts/verify_android_release.sh
```

The release build no longer falls back to the shared Android debug key. With
no release inputs Gradle may produce an unsigned compilation artifact; the
verification script rejects anything unsigned or debug-signed.

Keep the keystore, alias, passwords, and certificate backup in the project's
private credential store. Losing the key prevents compatible in-place updates.

## iOS unsigned IPA (Sideloadly / AltStore)

The GitHub Release IPA is unsigned by design. Recipients re-sign it with
Sideloadly, AltStore, or another sideload tool using their own Apple ID. Do
not treat that file as tap-to-install on a stock iPhone.

## iOS ad hoc IPA

Ad Hoc export is optional and stays off CI. The bundle identifier is
`io.github.troyt666.jfzreader`. Create an explicit App ID, register the
intended devices, and create an Ad Hoc provisioning profile in the Apple
Developer account. Signing certificates and profiles stay outside Git.

For local Xcode team signing, copy
`app/ios/Flutter/Local.xcconfig.example` to
`app/ios/Flutter/Local.xcconfig` and set `NOVELIA_DEVELOPMENT_TEAM`. That file
is gitignored.

Copy `app/ios/ExportOptions.ad-hoc.plist.example` to a private location, replace
the Team ID and profile name, then archive/export using Xcode or:

```sh
cd app
flutter --no-version-check build ipa --release \
  --export-options-plist=/absolute/private/path/ExportOptions.ad-hoc.plist
```

The template uses Xcode's current `release-testing` export method (the former
`ad-hoc` method name is deprecated).

Every target device must be included in the profile. Re-export after adding a
device or renewing an expired certificate/profile.

## Release checklist

1. Increment `version` in `app/pubspec.yaml`.
   The installed Android and Apple package metadata, Settings screen, and
   diagnostics all derive from this value; do not add a separate UI constant.
2. Run `flutter analyze` and `flutter test`.
3. Build from a clean commit and inspect the app/package identifiers.
4. Verify the APK signature is not the Android Debug certificate.
5. Install over the prior signed build to prove signing continuity and local
   database/session migration.
6. Exercise anonymous, signed-in, offline, and expired-session paths without
   capturing credentials or content in logs/screenshots.
7. Record artifact sizes and SHA-256 hashes in the GitHub Release notes.
8. Confirm the GitHub Release APK verifies with `apksigner` and is not the
   Android Debug certificate. The unsigned IPA and un-notarized DMG are
   expected.

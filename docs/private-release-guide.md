# Private release guide

Status: signing inputs intentionally remain outside the public source tree.

## Distribution boundary

- Source code may remain public.
- The GitHub Release workflow publishes build-only APK, unsigned IPA, and DMG
  artifacts without consuming signing credentials.
- The workflow does not provide release signing or notarization. Use the
  private signing/export steps below before sharing an installable release
  with a restricted audience.
- The app has no self-updater. Installation and updates remain explicit user
  actions.

## GitHub Release automation

`.github/workflows/publish-release-artifacts.yml` runs after a GitHub Release is
published, checks out the release tag, runs `flutter analyze` and `flutter test`,
and attaches these assets to that Release:

- `JFZ-Reader-<tag>-android.apk` — Android release APK built without a
  keystore, so it is unsigned unless the workflow is deliberately extended
  with private signing inputs.
- `JFZ-Reader-<tag>-ios-unsigned.ipa` — an IPA assembled from the unsigned
  iOS device `.app` because Flutter skips IPA export with `--no-codesign`.
- `JFZ-Reader-<tag>-macos.dmg` — a DMG containing the macOS release `.app`;
  notarization is not performed.

The workflow can also be started manually with an existing Release tag to
rebuild and replace its assets. It does not create Releases, sign artifacts,
or notarize the macOS app.

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
ignored by Git. Automation should provide these protected environment secrets
instead:

- `JFZREADER_ANDROID_STORE_FILE`
- `JFZREADER_ANDROID_STORE_PASSWORD`
- `JFZREADER_ANDROID_KEY_ALIAS`
- `JFZREADER_ANDROID_KEY_PASSWORD`

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

## iOS ad hoc IPA

The bundle identifier is `io.github.troyt666.jfzreader`. Create an explicit App ID,
register the intended devices, and create an Ad Hoc provisioning profile in the
Apple Developer account. Signing certificates and profiles stay outside Git.

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
2. Run `flutter analyze` and `flutter test`.
3. Build from a clean commit and inspect the app/package identifiers.
4. Verify the APK signature is not the Android Debug certificate.
5. Install over the prior private build to prove signing continuity and local
   database/session migration.
6. Exercise anonymous, signed-in, offline, and expired-session paths without
   capturing credentials or content in logs/screenshots.
7. Record artifact sizes and SHA-256 hashes in private release notes.
8. Upload signed binaries only to the access-controlled distribution location;
   the automated GitHub Release assets remain build-only artifacts.

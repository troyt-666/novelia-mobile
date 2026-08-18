# Private release guide

Status: signing inputs intentionally remain outside the public source tree.

## Distribution boundary

- Source code may remain public.
- APK and IPA artifacts are shared only with the intended small audience.
- Do not attach private binaries to a Release in the public source repository;
  use a separate private distribution repository or another access-controlled
  channel.
- The app has no self-updater. Installation and updates remain explicit user
  actions.

## Android signing

Generate and retain one release key outside the repository. Run `keytool`
interactively so passwords never appear in shell history:

```sh
keytool -genkeypair -v \
  -keystore /absolute/private/path/novelia-reader-release.jks \
  -alias novelia-reader -keyalg RSA -keysize 4096 -validity 10000
```

For a local build, copy `app/android/key.properties.example` to
`app/android/key.properties` and fill it locally. That file and `*.jks` are
ignored by Git. Automation should provide these protected environment secrets
instead:

- `NOVELIA_ANDROID_STORE_FILE`
- `NOVELIA_ANDROID_STORE_PASSWORD`
- `NOVELIA_ANDROID_KEY_ALIAS`
- `NOVELIA_ANDROID_KEY_PASSWORD`

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

The bundle identifier is `dev.novelia.noveliaReader`. Create an explicit App ID,
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
8. Upload binaries only to the access-controlled distribution location.

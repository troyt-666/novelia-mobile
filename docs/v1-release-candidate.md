# Novelia Reader v1 release candidate

- Date: 2026-08-18
- Version: `1.0.0 (1)`
Status: software candidate verified; private signing inputs pending

## Verified

- `flutter analyze` passes and all 175 tests pass.
- Android release compilation succeeds at 60.2 MB. With no private keystore,
  the artifact is unsigned and the repository signature gate rejects it.
- macOS release compilation succeeds at 51.1 MB with no debug auth/account
  diagnostic markers in the production binary.
- The iOS Simulator debug target compiles successfully. Flutter does not
  support release-mode Simulator builds; a device IPA requires Apple signing.
- Generated Android, iOS, and macOS metadata agrees on version `1.0.0 (1)` and
  the display name `Novelia Reader`.
- The Android API 36 emulator upgraded in place from `0.1.0` to `1.0.0`, cold
  launched `MainActivity`, retained the existing SQLite database, and produced
  no launch or SQLite crash.
- Owned-account login, refresh, prompt-free macOS restoration, Favorite Folder
  metadata and row loading, Favorite add/remove, populated Reading History,
  its write path, and logout with local-state retention are verified.
- The reader keeps three future chapters warm with sequential speculative
  requests, deduplicates an overlapping boundary load, and stops prefetching
  after the first failure.

## Required before distribution

- Supply the private Android release keystore, build the signed APK, and run
  `scripts/verify_android_release.sh`.
- If iOS is included in v1, supply the Apple Team, registered-device profile,
  and release-testing export options, then build and install the IPA.
- Install each signed artifact over the previous private build and repeat the
  signed-in plus offline-resume smoke.
- Record the final signed artifact sizes, SHA-256 hashes, and signing
  certificate/profile identity in private release notes.
- Upload binaries only to the access-controlled distribution channel; never to
  the public source repository.

## Accepted v1 deferrals

- Physical Android/iOS reader profiling, explicitly deferred by the user.
- Live expired-session recovery, because the service exposes no practical way
  to revoke the app's current refresh session on demand; deterministic tests
  verify that a 401/403 clears only account credentials and preserves local
  reading data.
- Forum and comment posting/replies.
- Wenku browsing and EPUB rendering.
- Offline Comment Page caching, expanded ranking combinations, TTS,
  annotations, sync, dictionary lookup, and advanced customization.

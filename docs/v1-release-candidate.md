# JFZ Reader v1 release candidate

- Date: 2026-08-18
- Version: `1.0.0 (1)`
Status: software candidate and physical performance verified; private
distribution signing inputs pending

## Verified

- `flutter analyze` passes and all 177 tests pass.
- Android release compilation succeeds at 60.2 MB. With no private keystore,
  the artifact is unsigned and the repository signature gate rejects it.
- macOS release compilation succeeds at 51.1 MB with no debug auth/account
  diagnostic markers in the production binary.
- The iOS Simulator debug target compiles successfully. Flutter does not
  support release-mode Simulator builds. A Personal Team profile build now
  signs, installs, and launches on the connected iPhone; distributing an IPA
  still requires the appropriate private signing/export inputs.
- Generated Android, iOS, and macOS metadata agrees on version `1.0.0 (1)` and
  the display name `JFZ Reader`.
- The Android API 36 emulator upgraded in place from `0.1.0` to `1.0.0`, cold
  launched `MainActivity`, retained the existing SQLite database, and produced
  no launch or SQLite crash.
- A profile APK installs on the Android 16 arm64 phone through direct ADB
  installation and restores the persisted live reader. Repeated swipes and a
  fast drag stayed near the 90 Hz display cadence; the sampled compositor
  intervals contained no frame above 34 ms.
- The iPhone profile build completed a physical steady-scroll Animation
  Hitches trace with no recorded hitch or potential hang and no sampled frame
  lifetime above 18 ms.
- The optimized macOS reader replaces selectable paragraph editors with plain
  text, keeps two viewports laid out ahead, expands its semantic render window
  in 96-paragraph batches, and tracks only mounted paragraph contexts. A
  synchronized stress pass of rapid Page Down, Page Up, and repeated scrolling
  recorded no compositor-classified hitch or hang; manual fast trackpad
  scrolling was also accepted by the user.
- Owned-account login, refresh, prompt-free macOS restoration, Favorite Folder
  metadata and row loading, Favorite add/remove, populated Reading History,
  its write path, and logout with local-state retention are verified.
- The reader keeps three future chapters warm with sequential speculative
  requests, deduplicates an overlapping boundary load, and stops prefetching
  after the first failure.
- Search is a separate fourth destination and exposes the official six-source,
  type, rating, GPT/Sakura, and update/click/relevance controls. Discover keeps
  a switchable Recently Updated / Most Clicked feed.
- Manual Offline Download creation is non-blocking after the protected intent
  is saved. A credential-free live short-story probe completed catalog, TOC,
  chapter fetch, and protected-copy commit with zero failures.

## Required before distribution

- Supply the private Android release keystore, build the signed APK, and run
  `scripts/verify_android_release.sh`.
- If iOS is included in v1 distribution, supply the release-testing export
  options and intended private distribution profile, then build the IPA.
- Install each signed artifact over the previous private build and repeat the
  signed-in plus offline-resume smoke.
- Record the final signed artifact sizes, SHA-256 hashes, and signing
  certificate/profile identity in private release notes.
- Upload binaries only to the access-controlled distribution channel; never to
  the public source repository.

## Accepted v1 deferrals

- A formal VoiceOver/TalkBack, large-font, and device typography matrix. The
  physical performance/install checks are no longer deferred, but this broader
  assistive-technology pass has not been recorded as complete.
- Live expired-session recovery, because the service exposes no practical way
  to revoke the app's current refresh session on demand; deterministic tests
  verify that a 401/403 clears only account credentials and preserves local
  reading data.
- Forum and comment posting/replies.
- Wenku browsing and EPUB rendering.
- Offline Comment Page caching, expanded ranking combinations, TTS,
  annotations, sync, dictionary lookup, and advanced customization.

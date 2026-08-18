# Novelia Reader

Independent Flutter reader for macOS, Android, and iOS.

## Implemented vertical slice

- semantic Chinese/Japanese Aligned Blocks with Chinese-first rendering;
- Chinese-only and Chinese-Japanese Reading Modes;
- Youdao, GPT, and Sakura fixture sources with whole-chapter validation;
- Japanese-original fallback for Translation Pending or invalid revisions;
- a bidirectional, anchor-centered virtual chapter window;
- restoration by stable block ID under a neutral loading cover;
- center-only tap to toggle Reader Chrome, with no horizontal navigation;
- chapter catalog jumps, source selection, bookmarks, and focused appearance
  controls;
- Simplified Chinese interface localization and light/dark/system themes;
- anonymous general-rated catalog/search, detail, comment, and paginated
  Syosetu ranking requests with verified offline cache fallback;
- durable SQLite reading state, bookmarks, search history, cached content, and
  protected whole-novel downloads;
- download pause/resume/retry/remove management and Translation Pending refresh;
- native external-browser launch for original-work links.
- direct hosted account login with Keychain/Keystore-backed refresh sessions;
- paginated remote Favorite Folder contents and Reading History;
- Favorite Folder selection/creation plus confirmed removal contracts and a durable,
  latest-chapter-wins Reading History outbox that is cleared on sign-out.

Deterministic fixtures remain available for tests. Production composition uses
the anonymous Novelia-compatible gateway by default and enables account data
only after a locally entered login succeeds. Owned-account login, refresh,
secure macOS restoration, and Favorite Folder metadata have been live-verified.
Account rows and mutations remain opt-in live steps.

Use macOS as the default fast-feedback target:

```sh
flutter --no-version-check analyze
flutter --no-version-check test
flutter --no-version-check run -d macos
```

See `AGENTS.md` for the repeatable agent and test workflow. Android is designed
to run on the `novelia_api36` Apple-silicon ARM emulator; a physical Android
phone is optional. The iOS Simulator runtime is also available.

Validated build commands include:

```sh
flutter --no-version-check build macos --release
flutter --no-version-check build apk --debug
flutter --no-version-check build apk --release
flutter --no-version-check build ios --simulator --debug
```

Android release builds no longer fall back to Flutter's debug certificate.
Without private signing inputs the release APK is intentionally unsigned and
must not be distributed. See
[`docs/private-release-guide.md`](../docs/private-release-guide.md) for signing
inputs, verification, and the ad hoc iOS export flow.

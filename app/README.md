# Novelia Reader

Independent Flutter reader spike for macOS, Android, and iOS.

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
- Simplified Chinese interface localization and light/dark/system themes.

Content is deterministic fixture data. Networking, database persistence,
downloads, authentication, discovery, and account features remain later phases.

Use macOS as the default fast-feedback target:

```sh
flutter --no-version-check analyze
flutter --no-version-check test
flutter --no-version-check run -d macos
```

See `AGENTS.md` for the repeatable agent and test workflow. Android is designed
to run on the `novelia_api36` Apple-silicon ARM emulator; a physical Android
phone is optional. The iOS Simulator runtime is also available.

Validated build commands:

```sh
flutter --no-version-check build macos --debug
flutter --no-version-check build apk --debug
flutter --no-version-check build ios --simulator --debug
```

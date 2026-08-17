# Novelia Mobile

Independent Flutter implementation of a Chinese-first, bilingual Web Novel
reader for Novelia-compatible content.

The only imported artifact is `Novelia_v0.7.7.apk`. It is a behavioral and
interoperability reference, not a source-code dependency. No application source
has been recovered or copied.

## Current status

- Static APK audit: complete.
- Signed-out live-site feature audit: complete.
- Product and domain grilling baseline: complete.
- Phase 1 paired-reader spike: implemented; manually inspected on macOS. The
  requested Android/iOS physical-device profiling gate is explicitly deferred,
  not treated as passed.
- Phase 2 vertical slice: the production app is wired to the anonymous,
  general-rated Novelia gateway with truthfully offline cached startup, live
  search/source/state/translation/tag/sort criteria, continuous catalog paging,
  a service-ordered Syosetu ranking, on-demand details, paginated read-only
  comments, bounded dynamic reader windows, and explicit whole-novel downloads.
- SQLite schema v4 persists catalog/detail/TOC records, exact Japanese and
  Chinese chapter payloads, reader position, bookmarks, settings, recent
  searches, last route, download intents/tasks, and Cache Copy versus protected
  Offline Download retention.
- Translation Pending downloads are rechecked on later reconciliation and are
  atomically upgraded when the selected Chinese translation appears, without
  leaving the already-stored task or copy in an inconsistent state.
- Interrupted tasks restart atomically, bounded refresh work rotates fairly,
  R18 reclassification revokes stale anonymous access, and every successful
  chapter cache write reapplies the configured LRU budget without touching
  protected downloads.
- Current automated checkpoint: static analysis is clean and 144 tests pass,
  including a file-backed online-download, close/reopen, network-failure,
  offline-resume, and pending-translation-refresh contract. Release macOS and
  iOS Simulator builds pass.
- The Android rebuild remains environment-blocked because the current JNI
  dependency requests Android platform API 35 and this machine only has API 36
  and 37 installed; the supported SDK installer could not reach Google's
  repository during this checkpoint. Physical Android/iOS profiling remains
  explicitly deferred by the user and is not treated as a passed release gate.

## Documents

- [APK audit](docs/apk-audit-v0.7.7.md)
- [Live-site feature audit](docs/site-feature-audit-2026-08-16.md)
- [Domain language](CONTEXT.md)
- [Reimplementation plan](docs/reimplementation-plan.md)
- [Anonymous gateway contract](docs/anonymous-gateway-contract-2026-08-17.md)
- [Accepted cross-platform stack; physical gate deferred](docs/adr/0001-cross-platform-stack.md)
- [Continuous cross-chapter reading](docs/adr/0002-continuous-cross-chapter-reading.md)
- [Ongoing whole-novel downloads](docs/adr/0003-whole-novel-downloads-track-future-chapters.md)
- [SQLite local persistence](docs/adr/0004-sqlite-local-persistence.md)

## Reference artifact

| Property | Value |
| --- | --- |
| File | `Novelia_v0.7.7.apk` |
| Size | 10,566,833 bytes |
| SHA-256 | `5910672894d61de5fe0ccb2bd9d60aa3d90bd8c839eb939bfd52d54721dd1b11` |
| Package | `com.example.novelia` |
| Version | `0.7.7` (`versionCode` 4) |

Before implementation, preserve the APK unchanged and verify its hash whenever
it is used as a reference.

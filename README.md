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
  a paginated service-ordered Syosetu ranking, on-demand details, paginated
  read-only comments, native external-browser handoff to the original work,
  bounded dynamic reader windows, and explicit whole-novel downloads.
- Phase 3 account slice: the hosted username/password exchange is wired with
  password-in-memory-only handling, protected Android/iOS session storage,
  prompt-free macOS app-local session persistence, refresh/logout, truthful
  paginated remote Favorite Folders and
  Reading History, the one-folder/multi-folder favorite flow, confirmed
  Favorite removal with authoritative page reload, and a durable
  latest-chapter-wins Reading History outbox. Login, refresh, macOS
  restoration, and folder metadata have passed an owned-account smoke.
- SQLite schema v5 persists catalog/detail/TOC records, exact Japanese and
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
- Reader launch is cache-first: a cached target and cached neighbors paint
  immediately, live revalidation runs without blocking the reader, and an
  uncached neighbor is deferred until the reader approaches that boundary.
- The Library exposes truthful download failure details plus pause, resume,
  retry, and confirmed removal controls. Removing an Offline Download preserves
  local reading progress and bookmarks.
- Current automated checkpoint: static analysis is clean and 173 tests pass,
  including a file-backed online-download, close/reopen, network-failure,
  offline-resume, and pending-translation-refresh contract. Release macOS and
  Android compilation and the iOS Simulator build pass. Android releases no
  longer fall back to the debug certificate: without external private signing
  inputs the 60.2 MB compilation artifact is unsigned and rejected by the
  repository verifier. The debug APK also installs and reaches a resumed
  MainActivity on the `novelia_api36` emulator without a launch crash.
- A bounded anonymous live-network smoke pass covers catalog paging with retry,
  both default ranking pages, detail and comments, adjacent/latest reader
  boundaries, a complete seven-chapter Sakura download, actual SQLite
  close/reopen, and offline reader restoration. No account credentials were
  required. A live ranking synchronization race discovered during the pass is
  covered by a permanent regression test.
- The JNI/Android build issue is resolved. Physical Android/iOS typography,
  accessibility, and performance profiling remains explicitly deferred by the
  user and is not treated as a passed release gate.

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
- [Private APK/IPA release guide](docs/private-release-guide.md)

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

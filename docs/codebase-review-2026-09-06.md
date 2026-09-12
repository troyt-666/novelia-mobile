# Codebase review and incremental refactoring

## Baseline and scope

The review found repeated validation/conversion, dispersed state ownership, and
some tests coupled to implementation text. The existing SQLite transaction and
gateway boundaries remain useful; no new framework or dependency is needed.

Baseline: static analysis reported no errors and all 261 existing Flutter tests
passed. A separate fixture test reproduced the stale account-refresh failure
below. These findings describe the code, not the model that generated it.

## Findings

| ID | Priority | Finding | Intended change |
| --- | --- | --- | --- |
| R1 | P1 | An old account's failed refresh clears a newly logged-in account. Successful refreshes check session identity; failure handling in `restore`, `accessToken`, and `retry` does not. | Give refresh completion one owner; ignore stale successes and failures before changing credentials or account state. Add a regression through the public controller API. |
| R2 | P2 | The root widget's `build` reads every cached novel and its full TOC, then projects reading progress, downloads, and bookmarks. Unrelated UI updates repeat synchronous database work. | Move local-library projection out of `build`; refresh it on relevant data changes and load only the details required by the shelf. |
| R3 | Simplification | `novelia_content_checksum.dart` implements SHA-256 despite the existing `crypto` dependency. | Use `crypto.sha256`, preserving JSON encoding, digest format, and existing persisted revisions. |
| R4 | Simplification | Live outline/detail responses are mapped in the content coordinator and mapped again when cached. Account rows and download TOC hydration repeat this pattern. | Cache the already-mapped domain value. Keep wire validation at the initial conversion boundary. |
| R5 | Simplification | Login/R18 checks and verified/revoked novel state are repeated across content operations and cache restoration. | Consolidate equivalent checks while preserving anonymous access restrictions and cached-content behavior. |
| R6 | Simplification | EPUB store validation fully parses the archive, discards the result, and the reader parses it again. | Pass the parsed document to the reader; retain validation and corrupt-cache recovery. |
| R7 | Test design | Some tests assert exact JS expressions, script commands, or dependency version strings rather than observable results. | Replace implementation-coupled assertions when the corresponding path is refactored. Preserve output, identity, signing, navigation, and sanitization contracts. |
| R8 | Product behavior | Invalid display statistics, including translation counts above the total, reject a whole catalog refresh or prevent opening details. The current contract explicitly requires this. | A separate behavior change can represent invalid statistics as unknown while preserving valid content and strict paragraph alignment. Update the contract and tests together. |
| R9 | Architecture | `main.dart` owns composition, three paginated feeds, account history sync, download scheduling, and local-library projection. Recently Updated has two writers. | Extract the actual feed and history-sync responsibilities, giving each state one owner; keep application composition small. |
| R10 | Architecture | `reader_screen.dart` combines window loading, anchor restoration, pagination calculations, body widgets, and settings panels. | Extract pagination and self-contained UI components using explicit inputs; preserve navigation, restoration, selection, and accessibility behavior. |

Relevant code:

- R1: `app/lib/core/account/account_session_controller.dart`
- R2/R9: `app/lib/main.dart`
- R3: `app/lib/gateway/novelia/novelia_content_checksum.dart`
- R4/R5: `app/lib/gateway/novelia/novelia_content_coordinator.dart`,
  `novelia_content_cache_adapter.dart`, `novelia_download_coordinator.dart`
- R6: `app/lib/features/wenku/wenku_epub_store.dart`,
  `wenku_details_screen.dart`, `wenku_reader_screen.dart`
- R7: `app/test/wenku_reader_contract_test.dart`,
  `app/test/release_configuration_test.dart`
- R8: `app/lib/gateway/novelia/novelia_domain_adapter.dart`
- R10: `app/lib/features/reader/reader_screen.dart`

## Order and completion checks

1. **First batch — account correctness and redundant processing (R1/R3/R4/R6).**
   Fix session races, replace hand-written hashing, reuse mapped content and
   parsed EPUBs. Verify stale refresh completion, persisted checksum
   compatibility, cache/live parity, download hydration, and EPUB reopen and
   corruption behavior. Status: completed on 2026-09-06.
2. **Library and feed ownership (R2/R9).** Move database projection out of
   widget builds; separate feed state and history synchronization. Verify shelf
   updates after reading/downloading, account isolation, pagination, refresh,
   and stale-request handling. Status: completed on 2026-09-06.
3. **Content-policy consolidation (R5).** Preserve allowed/denied outcomes
   across live, cached, and downloaded content while removing duplicate
   decisions. Status: completed on 2026-09-06.
4. **Reader decomposition and relevant test cleanup (R10/R7).** Move cohesive
   components, not arbitrary line ranges. Verify reading anchors, page turns,
   source changes, settings, and native WebView behavior for affected paths.
   Status: R10 and R7 completed on 2026-09-06. See Batches 4 and 6 for the
   separate reader implementation and WebView/release test changes.
5. **Display-statistics behavior (R8).** Specify the unknown-statistic display
   and update `anonymous-gateway-contract-2026-08-17.md` with its tests before
   changing the strict rule. Status: completed on 2026-09-06 as an explicit
   behavior change.

Run focused checks for each batch and static analysis plus the existing suite
at its completion. Record actual results below; do not infer runtime behavior
from source-string checks.

## Boundaries to preserve

- SQLite migrations and atomic payload/copy/task commits.
- Download cancellation, pause/resume, stale-write protection, and protected
  offline copies.
- Shared in-flight requests and session isolation.
- Original/translation paragraph alignment and Japanese-original fallback.
- HTTP host/redirect controls, EPUB sanitization and resource limits, and
  release-package integrity/signature checks.
- Existing anonymous versus signed-in access behavior. The navigation
  provenance restriction is an application assumption documented in
  `anonymous-gateway-contract-2026-08-17.md`; removing it would be a distinct
  product-policy change, not incidental cleanup.

## Completed batches

### Batch 1 — completed 2026-09-06

- **R1:** Refresh success and failure now update state through the same mutation
  queue and check the originating session and epoch. Login/logout detach the
  previous refresh; stale completion returns no token and cannot change the
  newer account. Local restoration also uses the queue. Background token
  network failures retain the existing signed-in UI; explicit restore/retry
  failures can report unavailability.
- **R3:** Replaced the manual SHA-256 implementation with the already-installed
  `crypto` package. JSON encoding and lowercase hexadecimal revision IDs are
  unchanged; no data migration is required.
- **R4:** `cacheOutline` and `cacheDetails` now consume `CatalogNovel` values.
  Content loading, account lists, and download TOC hydration reuse their
  already-validated mapping. Cached-content access checks remain in place.
- **R6:** The EPUB store returns the parsed document from load/save, and the
  details screen passes it directly to the reader. The saved file still contains
  the original bytes; malformed cached archives are still removed. EPUB
  rendering and sanitization code are unchanged.

Validation: the six old-account failure cases initially produced five failures;
all now pass. Added a separate background-token failure regression. Static
analysis reports no errors, all **268 Flutter tests pass**, and the diff passes
whitespace checks. The EPUB store test checks original bytes on disk and matching
rendered HTML after reopening, in addition to corrupt-cache removal. No native
WebView rendering changes or native-device claims are included in this batch.

Production Dart code: **218 net lines removed**, with no added dependency or
database migration.

### Batch 2 — completed 2026-09-06

- **R2:** `LocalLibrarySnapshot` owns continued reads, bookmarks, protected
  downloads, and storage totals. It loads only titles referenced by local
  reading/download state and retains outline fallback when detail restoration
  fails. The root widget reuses this snapshot during builds. Reading return,
  navigation, account/content changes, download changes, and cache operations
  refresh it; Download Management explicitly reloads progress when polling.
  Restricted cached or hydrated titles remain filtered for signed-out users.
- **R9 feeds:** `NoveliaCatalogController` owns search, Recently Updated, and
  Most Clicked. Each feed has independent pagination and request generations;
  search no longer writes Recently Updated. The same in-flight query can still
  serve multiple feeds without another network request. Refresh supersedes old
  pagination; unavailable popularity pages retain live ordering and expose retry.
- **R9 history:** `RemoteHistorySync` owns history deduplication, outbox draining,
  and account-switch clearing. Disposal stops pending completions from touching
  a closed repository. The existing persistent outbox and account rules remain.

`main.dart` decreased from **1,795 to 1,148 lines** in this batch. This measures
responsibilities moved out of the root widget, not net code deletion. There is
no new framework, dependency, or database migration.

Validation: all **273 Flutter tests pass**, including five new regressions for
feed independence and shared requests, stale search/pagination, popularity-cache
fallback, selective shelf loading/account access, and snapshot reuse/refresh.
Existing persistence, download, runtime-wiring, and account-isolation tests pass.
Whitespace checks pass. The Dart analysis server completed with **zero issues**
when invoked directly with the app as its analysis root; the MCP and standard
CLI launch paths stalled, so this run used the SDK's analysis-server snapshot.

### Batch 3 — completed 2026-09-06

- **R5 entry checks:** Detail, chapter, and comment requests now use one
  restriction check. Synchronous chapter-cache reads use the same decision
  without triggering cleanup. Removed repeated checks from the private
  provenance helpers after verifying every caller checks access first.
- **R5 state:** Renamed the verified-ID set to reflect that signed-in loads can
  also verify R18 titles. Verification and later revocation remain separate
  facts: old general-content objects cannot bypass a later R18 classification.
  Cached fallbacks and cache writes reuse the same remembered-denial predicate.
- **R5 cleanup:** Reading and downloading share `revokeRestrictedNovelCache`.
  It marks metadata that must survive for downloads, then evicts expendable
  content through the existing repository boundary. Protected copies and
  payloads remain available for a subsequent authorized session.
- Combined equivalent current/previous-outline restriction branches. Kept
  validation at live mapping and cache restoration boundaries, the provider
  allowlist, and the existing verified-navigation requirement. These checks
  protect distinct inputs; removing them would change behavior.

Validation: **36 focused tests and all 277 Flutter tests pass**. Four new cases
cover general/R18 access across all reading entry points after logout and
re-login, rejection of unverified hydrated objects before network access, and
download reclassification with protected-copy retention and anonymous restart
denial. The SDK analysis server reports **zero issues** using the direct
invocation established in Batch 2. Whitespace checks pass.

Production Dart code: **62 net lines removed** in this batch, counting the shared
cleanup function. No new dependency, policy framework, or database migration.

### Batch 4 — completed 2026-09-06

- **R10 pagination:** `ReaderPagination` consumes the loaded stream window,
  settings, text scale, and available dimensions. It owns page composition,
  oversized-text fragments, and stable-position lookup. The screen keeps one
  pagination result instead of separately owning page and lookup collections.
  Removed the redundant first-page lookup map and the unused index helper.
  Text measurements now release their `TextPainter` resources.
- **R10 components:** `reader_body.dart` owns chapter boundaries, aligned text,
  illustrations, and loading/error views. `reader_controls.dart` owns chrome,
  catalog/bookmark navigation, translation selection, and appearance settings.
  Components receive explicit data and callbacks. Settings return the existing
  `ReaderSettings` value directly, removing the one-field result wrapper.
- The screen retains async window loading, scroll/selection events, restoration,
  and position persistence. Existing widget keys and accessibility labels are
  preserved. No new state-management framework or native rendering path.
- Fixed a termination bug encountered in the extracted prefix search: adjusting
  a midpoint off a UTF-16 surrogate boundary could leave its search bounds
  unchanged. The search now advances past the original midpoint while preserving
  whole surrogate pairs, including when one glyph exceeds available height.
- **R7 scope:** The affected Flutter reader already has behavioral tests for
  selection, settings preview/cancel/apply, bookmarks, anchors, and navigation.
  Retained those tests and added outcome-based pagination checks. Remaining
  source-string assertions in Wenku WebView and release configuration are still
  tracked under R7; those production paths were not changed in this batch.

Validation: all **45 existing reader interaction tests**, **four new pagination
tests**, and the full **281-test Flutter suite pass**. New tests check bilingual
text preservation at narrow/wide widths, stable-position lookup, oversized emoji
termination, and Japanese fallback when translation is unavailable. The direct
SDK analysis-server run reports **zero issues**. Whitespace checks pass. These
results cover Flutter test rendering; no new native-device/WebView claim.

`reader_screen.dart` decreased from **4,528 to 1,967 lines**. Total reader code is
approximately unchanged (**4,533 lines** across four files); the improvement is
independent pagination and component ownership, not a line-count reduction.

### Batch 5 — completed 2026-09-06

- **R8 contract:** Updated the display-statistics policy before implementation.
  Decoded negative totals, points, character counts, and visits become unknown.
  A source's coverage becomes unknown when its counts are negative or exceed
  the reported total. Other valid sources and neighboring novels remain usable.
- **R8 mapping:** Catalog, rankings, and details now share the same normalization.
  Removed ranking-specific capping, which could turn inconsistent statistics
  into an apparent complete translation. Valid TOC metadata still supports
  reader launch and download reconciliation when reported totals are unknown.
- **R8 display/cache:** Unknown coverage has nullable counts, displays `统计未知`,
  has no progress bar, and does not match translated-source filters or claim
  completion. Negative optional scalar statistics use the existing absent-value
  presentation. SQLite coverage JSON stores nulls and reads existing integer
  records without a schema migration. Cache restoration retains unknown values.
- DTO type checks, page metadata, R18/access rules, TOC uniqueness, chapter
  identity, and paragraph alignment retain their existing validation.

Validation: **78 focused tests and all 285 Flutter tests pass**. Four new cases
cover mixed valid/invalid catalog statistics, detail/cache preservation plus
duplicate-TOC rejection, unknown-statistic rendering with an actionable reader
button, and live reading/protected downloading despite bad counts. Updated the
old ranking-cap test to require unknown coverage. Existing database migration,
access-isolation, and alignment tests pass. Direct SDK analysis reports **zero
issues**, and whitespace checks pass.

### Batch 6 — R7 completed 2026-09-06

- **WebView:** Replaced assertions about exact JavaScript expressions, CSS
  declarations, and gesture-handler source with a macOS WKWebView test of the
  generated EPUB. The fixture covers a cover page and a multi-page resource,
  including hostile publication script/CSS and a broken embedded image. Checks
  exercise actual column layout, final-page reachability, fraction/fragment
  restoration, scrolling/snap, chapter boundaries, keyboard/editable-field
  behavior, taps/swipes, language roles, and appearance changes.
- Kept portable tests for EPUB navigation, embedded images, ruby preservation,
  script/event removal, CSS escape prevention, and persistent/corrupt EPUB
  storage. The native harness uses AppKit's application loop so WebKit can
  deliver layout frames; a generic run loop alone did not complete readiness.
  Failures retain the HTML fixture, JavaScript error output, and a snapshot.
- **Release output:** The actual update-site script now runs against temporary
  artifacts. Its JSON is decoded by `AppUpdateManifest`; tests compare artifact
  size/checksum/URL, release notes, AltStore identity, and Sparkle enclosure
  signature metadata. Invalid release tags, missing artifacts/signature files,
  and mismatched signed lengths fail through the script's real exit status.
- **APK verification:** Runs the actual verifier with a fixture `apksigner`
  executable to exercise success, debug-certificate rejection, and tool failure.
  This verifies the shell boundary's decisions, not cryptographic signing of
  a production APK. No real signing keys or published artifacts are involved.
- **Configuration:** Parse plist key/value pairs and exercise `git check-ignore`
  instead of matching key presence and ignore-file text. Compare the declared
  Sparkle package/tool versions rather than pinning a literal version or digest
  in tests. Retain narrow static assertions for native channel wiring and
  release/signing pipeline configuration; these are configuration checks, not
  claims that all platform binaries or the hosted release workflow ran.

Validation: **7 focused release tests and the full 288-test Flutter suite pass
on macOS**, including the native WKWebView fixture. Direct SDK analysis reports
**zero issues**, and whitespace checks pass. `flutter --no-version-check test`
includes the WebView check on macOS with Xcode/Swift installed; non-macOS hosts
explicitly skip that native check while retaining portable EPUB tests. Release
script tests use the same local shell, jq, and checksum tools as the scripts.

All planned implementation and test-cleanup batches are complete. No live
account/content probes, signing with real credentials, or publication were
performed as part of these batches.

## Follow-up review and cleanup — 2026-09-12

Reviewed application composition, discovery/search, account and history sync,
offline storage/downloads, content access and loading, both reader paths,
updates, platform bridges, and build/release scripts. The review followed the
actual callers and state transitions: each fact needs one owner, persisted
changes need a truthful result, and validation should protect a real boundary.
The main remaining excess was obsolete parallel paths and repeated work inside
the existing architecture. Another architectural layer was not needed.

### Findings fixed

| Finding | Change and result |
| --- | --- |
| Shell accepted a catalog controller plus duplicate feed snapshots, flags, callbacks, and its own criteria copy. | Require the existing controller and read its state directly. Search criteria now follow external controller updates. Keep independent feed notifications so searches do not rebuild populated discovery feeds. |
| Production widgets retained test-only synchronous reader launch, legacy search/favorite callbacks, an unused results screen, and prototype messages. | Remove the unused paths. Shell tests use the existing controller, reader-window factory, and real favorite-folder flow with fixture services. |
| A single-title access check decoded all cached titles. One unrelated corrupt row could make an ordinary title appear to require login; the same scan pattern affected restriction markers and revocation. | Use the repository's existing novel-ID filter in all three paths. No new query API or cache layer. A regression reproduces the false denial on the old code and verifies restricted-copy retention and anonymous restart denial. |
| Offline storage projected the same copies twice, re-sorted already ordered SQL results, maintained duplicate totals, and split one repository into three unused subinterfaces. | Read copies once for shelf and storage summary, derive overall totals from per-title totals, retain SQL ordering, and keep one existing repository interface. |
| Download execution repeated task reload helpers, synchronous reads immediately after writes, equivalent validation transitions, and resume/retry bodies. The shell and detail screen both caught download errors. | Share the actual state check, remove redundant reads and branches, and let the detail screen own success/failure feedback. Keep task/intent rereads after asynchronous work and atomic completion. |
| Explicit logout swallowed local credential-deletion failure and presented a signed-out state while credentials remained on disk. History was also cleared before logout succeeded. | Require local deletion to succeed before reporting logout. Show a failure with a working retry button. Clear account history through the existing session listener. Remote logout remains best effort; unusable credentials are still removed from memory even if storage cleanup fails. |
| Wenku pagination tested vertical alternatives despite a constant horizontal axis. | Remove unreachable branches. Preserve the existing layout, navigation, sanitization, and resource limits. |

### Architecture retained

- Session identity/epoch checks and the mutation queue prevent stale requests
  from changing a newer account. They address tested races.
- SQLite transactions, task revisions, cancellation checks after awaits, and
  protected-copy ownership prevent stale writes and lost offline content.
- Wire/cache validation, translation alignment, restricted-content rules,
  EPUB sanitization, and release integrity/signature checks protect distinct
  boundaries. Removing them would change the product's guarantees.
- Reader anchor and scroll geometry handle measured layout changes. Splitting
  more files or replacing these mechanisms solely to reduce file size would
  not simplify their responsibilities.

### Validation and scope

Static analysis of `lib`, `test`, and `integration_test`: **zero issues**.
The full local Flutter suite passes **330 tests**, including actual macOS
WKWebView layout/navigation/sanitization checks. Both the unrelated-corrupt-cache
case and the failed-local-logout retry case were observed failing before their
respective fixes. Existing account isolation, download transitions, persistence,
reader interaction, and release-script tests also pass. Whitespace checks pass.

Production Dart code: **309 net lines removed across 15 files**. This is a code
size measurement, not a runtime benchmark. No dependencies or database schema
changes were introduced. Validation was local; no phone deployment, live account
probe, signing, or publication was performed. Pre-existing HarmonyOS identifier
and documentation edits were left untouched.

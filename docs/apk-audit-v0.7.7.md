# Novelia v0.7.7 APK audit

Date: 2026-08-10  
Scope: static inspection only

## Executive summary

The APK is a small, hobby-style Flutter application rather than a native
Android app. Its product logic is AOT-compiled into `libapp.so`, so conventional
Java/Kotlin decompilation does not recover usable Dart source. Static symbols do,
however, expose enough neutral facts to map its screens, storage model, API
families, and bilingual reader settings.

The app is a useful behavioral reference, but it should not be used as a code
base. It is arm64-only, uses a `com.example` package, is signed with an Android
debug certificate, requests obsolete/broad storage access, permits cleartext
traffic, and contains an HTTP self-update endpoint. Those choices must not be
copied into a production Android/iOS implementation.

## Artifact identity and integrity

| Property | Finding |
| --- | --- |
| File | `Novelia_v0.7.7.apk` |
| ZIP entries | 382 |
| Size | 10,566,833 bytes |
| SHA-256 | `5910672894d61de5fe0ccb2bd9d60aa3d90bd8c839eb939bfd52d54721dd1b11` |
| ZIP integrity | Valid |
| Package | `com.example.novelia` |
| App label | `Novelia` |
| Version | `0.7.7`, code 4 |
| Minimum Android | API 21 |
| Target/compile Android | API 35 |
| Android Gradle Plugin | 8.7.3 |

The signing certificate is an Android Debug certificate. Its SHA-256 fingerprint
is `7C:DB:0A:30:0D:FA:AE:89:FA:46:EF:E7:7E:A9:5F:37:EE:49:27:CC:E1:7D:8D:B5:3C:EB:8C:A2:C5:A9:DE:DB`.
This package/signing identity is not a viable production update lineage.

## Packaging and implementation technology

- Flutter AOT application.
- One Android DEX containing the Flutter host and plugin glue.
- Dart product logic in stripped `arm64-v8a/libapp.so`.
- Flutter runtime in `arm64-v8a/libflutter.so`.
- Only the `arm64-v8a` ABI is packaged.
- The only product image asset is an avatar. CJK body fonts are not bundled, so
  the reader relies on platform font fallback.

Recovered Flutter/Dart dependencies include Provider, Dio, HTTP, cookie jar,
SQLite, shared preferences, cached images, connectivity, Markdown, file picker,
open/share, image picker, path provider, URL launcher, permissions, shimmer,
internationalization, and UUID support.

## Android manifest findings

The launcher activity is
`com.example.novelia_app_flutter.MainActivity`. The manifest requests:

- `INTERNET`
- `ACCESS_NETWORK_STATE`
- legacy read/write external storage
- `MANAGE_EXTERNAL_STORAGE`

The application enables `usesCleartextTraffic` and
`requestLegacyExternalStorage`. Providers are registered for file sharing,
image picking, and opening downloaded files. There is no inbound website deep
link.

For a replacement app:

- use Android scoped storage and the system document picker;
- use the iOS app sandbox, document picker, and share sheet;
- do not request all-files access;
- require HTTPS;
- let the Play Store/App Store handle app updates.

## Recovered product surface

The AOT symbol table exposes 81 project-owned Dart file paths. They identify the
following features without revealing source implementations:

- home and catalog browsing;
- web-novel and Wenku tabs, filters, cards, details, volumes, and files;
- forum categories, articles, comments, and saved articles/folders;
- account login, favorites, favorite folders, and reading history;
- chapter cache, saved book details, downloads, and TXT/file export;
- API, general, storage, theme, and reader settings;
- update checking;
- a dedicated reader package with chapter models, provider, page, drawer,
  title widget, paragraph renderer, and settings sheet.

The release forum post independently describes home, favorites, forum/history,
web-novel reading, two API sources, offline cache, and TXT export. It explicitly
does not implement the website's workspace feature.

## Network and authentication clues

Primary hosts:

- `https://n.novelia.cc`
- `https://auth.novelia.cc`

Packaged fallbacks:

- `https://n.sakura-share.one`
- `https://auth.sakura-share.one`

Recovered path families:

- `/api/novel`
- `/api/wenku`
- `/api/article`
- `/api/comment`
- `/api/user/favored`
- `/api/user/favored-web`
- `/api/user/favored-wenku`
- `/api/user/read-history`
- `/api/user/read-history/paused`
- `/api/v1/auth/login`
- `/api/v1/auth/refresh`

Strings indicate bearer authorization, access-token persistence, a persistent
cookie jar, separate content/auth base URLs, and retry after a `401` refresh.
The app persists `api_base_url` and `api_custom_urls`, so source selection is
configurable.

No embedded password, private key, or static access token was found. Static
inspection does not prove the exact request/response schemas or whether use of
these endpoints by a new client is authorized.

The APK also contains this cleartext self-update manifest:

`http://4g58x07700.qicp.vip:8418/muchun/novelia_update_server/raw/branch/main/version.json`

It must not be reproduced.

## Offline storage clues

The database filename is `novelia.db`. Recovered tables include:

- `cached_chapters`
- `cached_novel_details`
- `download_tasks`
- `file_downloads`
- `saved_articles`
- `saved_article_folders`
- `favorite_folders`
- `favored_web_novels`
- `favored_wenku_novels`

Notable schema facts:

- a cached chapter is keyed separately from provider, novel, and chapter IDs and
  stores a file path, timestamp, and byte size;
- cached novel details store provider/novel IDs, JSON, update time, and chapter
  count;
- downloads persist status and progress;
- favorites are folder-scoped and distinguish provider/novel IDs;
- saved articles retain author, creation time, saved time, content, and folder.

The replacement should use a new schema rather than preserve this one. In
particular, normalized chapter blocks and translations should be first-class
records instead of opaque JSON/file-path caches.

## Paired Japanese/Chinese reader evidence

The APK contains dedicated `buildJapanese` and `buildChinese` paths and separate
translation arrays named for GPT, Sakura, Baidu, and Youdao. Reader preferences
include:

- `reader_translation_mode`
- `reader_show_translation`
- `reader_selected_translation_source`
- `reader_font_size_main`
- `reader_font_size_sub`
- `reader_font_weight_index`
- `reader_line_height`
- `reader_page_padding`
- `reader_enable_custom_indent`
- `reader_custom_indent`
- `reader_primary_opacity`
- `reader_secondary_opacity`
- `storage_enabled_translations`
- `storage_translation_priority`
- `storage_preload_count`

This strongly supports a model of paired original and translated paragraph
collections with independent visual styling. Static strings do **not** reveal
the exact pairing, mismatch, revision, or missing-translation algorithm.

The new reader should model semantic pairs, not rendered lines. Japanese and
Chinese text wrap differently across fonts, widths, accessibility sizes, and
platforms; visual line numbers cannot be a stable alignment key.

## What static inspection cannot establish

- Exact JSON schemas, pagination, and error payloads.
- Whether authentication is a supported public mobile flow.
- The exact paragraph alignment and fallback rules.
- Reading-position synchronization and conflict behavior.
- Cache eviction semantics and failed-download recovery.
- iOS behavior, because no iOS build exists.
- Current service terms or permission to reuse APIs, content, name, or artwork.

These items require an authorized test account and black-box behavior capture on
an arm64 Android device. Do not bypass TLS, anti-bot controls, authentication,
rate limits, or access restrictions.

## Independent-reimplementation boundary

This audit records interoperability and behavior facts. It does not recover or
copy Dart source. Because the same implementation effort has seen static symbol
names, this should be described as an **independent reimplementation**, not an
airtight two-team legal clean room.

Do not copy the original app's code, icons, artwork, wording, package name,
certificate, database contents, or proprietary novel content. Before public
distribution, confirm the site's API/content terms and obtain permission for
third-party service access and branding. The website's workspace feature remains
out of scope.

## Sources

- [Original release forum post](https://n.novelia.cc/forum/694648120d08846ab2e3d5b6)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Google Play intellectual-property policy](https://support.google.com/googleplay/android-developer/answer/9888072)

# JFZ Reader

JFZ Reader is a Chinese-first bilingual reader for Novelia-compatible web
novels. Read Chinese translations alongside Japanese originals, keep your
place, and continue reading when you are offline.

## Features

- Browse discovery feeds and search a catalog by source, type, rating,
  translation provider, and sort order.
- Read in Chinese-only or Chinese–Japanese mode with chapter navigation and
  adjustable reading appearance.
- Resume from saved reading progress and use bookmarks and recent searches.
- Download whole novels for offline reading with pause, resume, retry, and
  removal controls.
- Sign in when needed for account features such as Favorites and Reading
  History; general browsing and reading can remain anonymous.
- Open the original work in the system browser.
- Use light, dark, or system theme settings.

## Supported platforms

- Android
- iOS
- macOS

The release version is declared in `app/pubspec.yaml` and shown from the
installed package metadata inside the app. Published builds are on the
[Releases](https://github.com/troyt-666/novelia-mobile/releases) page:

- **Android** (`JFZ-Reader-<tag>-android.apk`) — signed installable APK.
- **iOS** (`JFZ-Reader-<tag>-ios-unsigned.ipa`) — unsigned; re-sign with
  Sideloadly, AltStore, or a similar tool. It will not install by opening the
  file on a stock iPhone.
- **macOS** (`JFZ-Reader-<tag>-macos.dmg`) — not notarized. If Gatekeeper
  blocks it, right-click the app and choose Open.

Installed builds check the project's HTTPS release metadata and show an update
action in Settings. Installation is still confirmed by the user. AltStore
Classic users can add the
[JFZ Reader source](https://troyt-666.github.io/novelia-mobile/altstore-source.json)
once; Sideloadly users install each new IPA over the existing app with the same
Apple ID and bundle identifier.

## Offline reading

JFZ Reader restores cached content and reading position locally, so a novel
that has already been opened can remain available when the network is
unreliable. Whole-novel downloads are kept separately from the cache and can
be managed from the Library.

## About the project

JFZ Reader is an independent application and is not affiliated with Novelia,
its operators, or the owners of third-party content. Content availability,
translations, and account-only catalog levels depend on the connected
service.

For development setup, architecture notes, and test commands, see
[`app/README.md`](app/README.md) and [`CONTEXT.md`](CONTEXT.md).

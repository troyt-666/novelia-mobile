# Novelia live-site feature audit

Date: 2026-08-16  
Scope: signed-out, read-only inspection; no account mutations performed

## Discovery

- [Home](https://n.novelia.cc/) exposes Web Novels, Wenku, several source-native
  Rankings, Favorites, Workspace, Forum, and Settings. Its Web Novel shelf is
  Most Clicked.
- [Web Novel catalog](https://n.novelia.cc/novel) searches Chinese/Japanese title
  or author and filters by provider, publication state, and Translation Source.
  It sorts by update, clicks, or relevance and supports exact tag navigation.
- Catalog cards show both titles, provider/original link, tags, publication
  state, chapter total, per-source translation coverage, and update recency.
- [Syosetu Rankings](https://n.novelia.cc/rank/web/syosetu/1) demonstrate the
  broader Ranking model: native rank/points, genre, word count, update time,
  publication state, tags, Translation Source coverage, period, and status
  filters. Kakuyomu rankings are also exposed.

## Novel Details and comments

- A representative [Web Novel detail](https://n.novelia.cc/novel/hameln/232822)
  shows Chinese/Japanese titles, author/source navigation, start/favorite
  actions, publication state, length, update recency, views, synopsis, native
  points, tags, translation coverage, EPUB actions, comments, and a sectioned
  bilingual chapter catalog.
- No cover art was visible on the inspected Web Novel details.
- Novel Comments are a prominent, novel-specific discovery surface rather than
  Forum posts. The inspected work had many pages and nested replies discussing
  pacing, content warnings, translation/adaptation quality, and whether the work
  was worth continuing.
- [Settings](https://n.novelia.cc/setting) can hide Web Novel comments, confirming
  that comments are a first-class detail feature. The mobile baseline instead
  keeps them at the bottom after the chapter catalog, one page at a time, with
  all replies on that page visible.

## Reader and settings

- A [translated chapter](https://n.novelia.cc/novel/hameln/232822/1) confirms
  Chinese-first paragraph ordering in Chinese-Japanese mode.
- Content controls include Japanese, Chinese, both language orders,
  priority/parallel translation choice, ordered Youdao/GPT/Sakura sources,
  read-aloud language, chapter/scroll pagination, source labels, and indentation
  correction.
- Appearance controls include size, weight, line height, width, underline,
  theme, and primary/secondary opacity.
- The mobile baseline intentionally narrows this to Chinese-only and
  Chinese-Japanese reading, one selected source with no silent fallback,
  continuous cross-chapter scrolling, and focused typography/theme controls.

## Pending translation behavior

- [This Web Novel](https://n.novelia.cc/novel/syosetu/n6173mk) exposed more
  Japanese originals than Sakura translations during inspection.
- Opening an affected untranslated chapter in Chinese-Japanese mode produced
  missing-translation notices without a useful original body. This validates
  the mobile requirement to preserve/show the complete Japanese Original,
  record Translation Pending separately, and revalidate it later.

## Favorites and authentication

- Signed-out [My Favorites](https://n.novelia.cc/favorite/local) behaves primarily
  as a local EPUB/TXT/SRT file library with folders; it is not evidence of the
  APK's server-backed Web Novel Favorite Folders.
- Hosted [authentication](https://n.novelia.cc/auth?from=/favorite/local) exposes
  login, registration, and password recovery. Exact remote Favorite Folder and
  Reading History behavior still requires sanctioned account/API verification.

## Scope implications

- Keep read-only Novel Comments in the Web Novel MVP.
- Preserve discovery filters and a secondary Rankings route.
- Do not fabricate cover art, reproduce Workspace, or add EPUB rendering to the
  Web Novel vertical slice.
- Keep the local file-library route distinct from account-backed Favorites and
  the app's normalized Offline Downloads.

# Reader Experience v2 Product Requirements

- Status: Implementation baseline
- Owner: Novelia Mobile
- Target: Reader Experience v2 program
- Last updated: 2026-08-22

## 1. Summary

Novelia's reader reliably restores semantic positions, streams across chapter
boundaries, handles offline availability, and presents aligned Chinese and
Japanese text. Its primary interaction is nevertheless a continuous vertical
feed. Reader Experience v2 adds the navigation, progress, and appearance
controls users expect from a dedicated ebook reader while preserving Novelia's
bilingual and cross-chapter strengths.

The program introduces a screenful-based paged mode alongside the existing
scroll mode, predictable tap and swipe navigation, visible progress and chapter
navigation, live appearance customization, responsive layouts, and in-reader
bookmarks. It intentionally does not claim typesetter-grade print page numbers;
`Pages` means deterministic movement by a readable viewport.

## 2. Problem

The current reader has these user-facing gaps:

1. Readers cannot choose between continuous scrolling and page-oriented
   reading.
2. Left and right taps do not navigate, and there is no horizontal page gesture.
3. The reading surface does not show chapter or book progress or offer fast
   chapter-aware scrubbing.
4. Appearance settings cover only basic sizes, line height, width, opacity, and
   the application theme. They obscure most of the book while editing and do
   not preview changes live.
5. Bookmarks cannot be reviewed or navigated from inside the reader, and
   bookmarked passages have no in-content marker.

Together these gaps make the experience feel like a long article rather than a
purpose-built book reader.

## 3. Goals

- Let a reader choose continuous scroll or page-oriented reading and persist
  that preference.
- Make one-handed page navigation predictable without compromising access to
  reader controls.
- Make the reader's current location understandable and quickly navigable.
- Let readers tune the page for daylight, paper-like, low-light, and dark
  reading with immediate feedback.
- Preserve the current semantic reading position through layout, typography,
  source, theme, and orientation changes.
- Preserve continuous cross-chapter loading, offline boundaries, restoration,
  bookmarks, illustrations, and bilingual alignment.
- Keep all new controls accessible by semantics and large enough for touch.
- Make saved bookmarks visible and navigable without leaving the reader.

## 4. Program exclusions

- Typesetter-grade immutable pages or paragraph fragmentation across pages.
- Download, catalog, account, comment, or discovery redesigns.
- Cloud synchronization protocol changes for annotations or statistics.
- Text selection, highlights, notes, copy, in-book search, dictionary, and
  translation actions.
- Text-to-speech, sentence highlighting, audio synchronization, and sleep
  timers.
- Reading rulers, specialized accessibility presets, and a formal assistive-
  technology certification matrix. Baseline semantics remain required.
- Reading time, estimates, goals, streaks, and achievements.
- Commercial dictionary, translation, or speech services.
- Bundling large CJK font files. Font choices use platform families and
  safe fallbacks.
- Audio-book synchronization, recorded narration, and sleep timers.

## 5. Users and jobs

### Focused mobile reader

Wants to hold a phone in one hand, advance by tapping or swiping, and understand
where they are without repeatedly opening the chapter catalog.

### Bilingual reader

Changes between Chinese-only and aligned Chinese/Japanese presentation and
expects the same semantic paragraph to remain visible after reflow.

### Low-light reader

Needs a comfortable page color, text weight, spacing, and margins without
changing the appearance of the entire application.

### Keyboard or assistive-technology reader

Needs controls with stable semantics and navigation that remains usable without
depending exclusively on raw pointer zones.

## 6. Experience principles

- Content remains primary; chrome hides during active reading.
- Center means controls. Page-edge taps mean movement only in paged mode.
- A setting change must not lose the reader's semantic position.
- Progress is based on semantic chapter/block location, not raw scroll pixels.
- Unavailable adjacent content is a truthful boundary, not an endless spinner.
- Page-oriented mode is described as `Pages`, not as fixed print pagination.

## 7. Functional requirements

### R1. Reading layout mode

- Add `Scroll` and `Pages` layout choices to reader settings.
- Keep `Scroll` as the default for existing installations.
- Persist the selected layout in local app settings.
- `Scroll` retains free vertical scrolling and continuous cross-chapter reading.
- `Pages` advances or reverses by approximately one readable viewport, with a
  small overlap so the previous line remains visually recoverable.
- Page movement must clamp at available boundaries and trigger the existing
  adjacent-chapter loader when appropriate.
- Changing layout must restore the visible semantic block and intra-block
  offset as closely as the new layout permits.

Acceptance:

- Restarting the app restores the selected layout.
- Changing font, theme, source, or language mode does not reset the chapter.
- Existing dynamic-window and boundary-loading tests continue to pass.

### R2. Tap and swipe navigation

- When chrome is hidden in `Pages` mode:
  - left 25% of the reading surface moves backward;
  - center 50% reveals chrome;
  - right 25% moves forward.
- When chrome is visible, a content-area tap hides it without also moving.
- A horizontal swipe moves one screen in the swipe direction in `Pages` mode.
- Vertical drag remains the only direct content gesture in `Scroll` mode.
- Pointer movement, long press, child controls, and illustration interactions
  must not accidentally trigger page movement.
- Expose explicit previous and next semantic actions for accessibility and
  widget tests.

Acceptance:

- Side taps and horizontal swipes move the scroll position in `Pages` mode.
- Center taps toggle chrome without moving the reading position.
- Side taps do not move content in `Scroll` mode.
- A single gesture produces at most one page movement.

### R3. Reading progress and chapter navigation

- Display a compact progress label while chrome is visible:
  `Chapter current / total · current chapter percent`.
- Derive the within-chapter percentage from the active semantic block ordinal
  and the loaded chapter's block count.
- Show the novel-level chapter position even when bodies for other chapters are
  not loaded.
- Add previous-chapter and next-chapter actions.
- Add a discrete chapter-aware scrubber spanning the complete catalog.
- Scrubber preview shows the target chapter number/title before navigation is
  committed.
- Navigating to an unloaded chapter uses the existing `loadAround` path with
  its loading, retry, and offline behavior.

Acceptance:

- Progress updates after scrolling, paging, catalog jumps, and restoration.
- Scrubbing to a loaded chapter preserves the current loaded window when
  possible.
- Scrubbing to an unloaded chapter presents the existing truthful loading or
  failure state.
- Previous/next actions are disabled at the true catalog boundaries.

### R4. Live appearance controls

- Replace the full-height apply workflow with a compact, scrollable sheet whose
  changes update the underlying reader immediately.
- A cancel/close action restores the settings and theme that were active when
  the sheet opened; a done action keeps the live changes.
- Add a reset action for reader appearance defaults without changing language
  mode or translation source.
- Persist committed changes.

Appearance controls in scope:

- Reader palette: Paper, Sepia, Low Light, Dark, Black.
- Chinese and Japanese font size.
- Font family: System Sans and System Serif.
- Regular or bold body weight.
- Line height.
- Paragraph spacing.
- Horizontal page margin.
- Japanese secondary-text opacity.
- Maximum reading width for larger displays.

Acceptance:

- The reading surface visibly changes while a control is edited.
- Cancel restores the complete pre-sheet settings atomically.
- Done persists the complete settings atomically.
- Palette changes affect the reader surface and reader chrome without changing
  the application's global theme preference.
- Contrast remains legible for primary and secondary text in every palette.

### R5. Responsive layout

- Phone layouts remain a single column.
- Reading width and page margins adapt without horizontal clipping at supported
  text sizes.
- Larger displays retain the configurable maximum reading width.
- Add Auto, Single Column, and Two Columns choices. Auto uses one column on
  phones and may use two columns on sufficiently wide landscape/tablet/desktop
  viewports.
- In `Pages` mode, a two-column spread advances by one visible spread.
- Add Follow Device, Portrait, and Landscape orientation choices on supported
  mobile platforms. Unsupported desktop orientation choices remain visible but
  disabled with an explanation.
- Persist column and orientation preferences and restore the semantic anchor
  through layout changes.

### R6. Persistence and migration

- Add new reader setting columns through a forward-only SQLite migration.
- Existing databases receive defaults matching current behavior: Scroll,
  Paper-like palette, System Sans, regular weight, and current paragraph/margin
  spacing.
- Fresh databases and migrated databases produce equivalent settings.
- Unknown persisted enum values fail through the repository's existing
  validation rather than silently selecting an unrelated option.

### R7. Baseline accessibility and input

- All visible buttons, segmented controls, progress information, and sliders
  have useful semantic labels and values.
- The page surface exposes previous/next semantic actions in `Pages` mode.
- Touch targets meet Material's standard interactive dimensions.
- Reader progress is announced as one concise value rather than multiple noisy
  labels.

### R8. In-reader bookmarks

- Keep the existing one-tap bookmark toggle at the semantic reading anchor.
- Show a subtle marker beside bookmarked blocks without changing text flow.
- Add an in-reader `Bookmarks` view reachable from the catalog/navigation
  surface.
- List chapter, an excerpt from the bookmarked block, language context, and
  creation order.
- Tapping a bookmark navigates through the existing loaded/unloaded chapter
  paths.
- Removing a bookmark from the list updates the marker and persistent store.

Acceptance:

- Bookmarks created before this release appear in the in-reader list.
- Add, remove, restart, and bookmark navigation preserve semantic positions.
- Bookmark markers remain correct after translation-source or language changes.

## 8. Interaction specification

### Chrome hidden

| Layout | Left 25% | Center 50% | Right 25% | Vertical drag | Horizontal swipe |
| --- | --- | --- | --- | --- | --- |
| Scroll | No action | Show chrome | No action | Scroll | No action |
| Pages | Previous screen | Show chrome | Next screen | No free scroll | Turn screen |

### Chrome visible

- Tapping unobstructed book content hides chrome.
- Toolbar, scrubber, sheet, and catalog interactions consume their own taps.
- Chrome auto-hides after the current inactivity interval.

### Progress model

- Catalog progress: active catalog index divided by catalog chapter count.
- Chapter progress: active block ordinal plus intra-block fraction divided by
  loaded chapter block count.
- Displayed percentages are estimates and never claim stable print page numbers.

## 9. Technical constraints

- Keep `ReadingPosition` semantic: chapter ID, block ID, and intra-block offset.
- Reuse the existing render window and adjacent chapter data source.
- Avoid pre-laying out the full novel or loading every chapter body.
- Page movement uses the current scroll controller and viewport dimensions.
- Settings reflow must capture the anchor before rebuilding and restore it after
  the next frame.
- Do not add a plugin solely for reader brightness or orientation in this
  program when a Flutter/system API is sufficient.
- Isolate orientation handling behind a package-neutral interface so widget and
  persistence tests remain deterministic.
- Preserve stable `ValueKey` values and add keys for every new critical control.

## 10. Quality plan

- Model tests for defaults and `copyWith` behavior.
- SQLite tests for fresh schema, version migration, round-trip persistence, and
  legacy defaults.
- Widget tests for tap zones, swipes, mode switching, page clamping, progress,
  scrubber navigation, live preview, cancel, done, and reset.
- Persistence and widget tests for in-reader bookmark listing, markers,
  navigation, and removal.
- Regression tests for semantic restoration, bookmarks, illustrations,
  translation pending states, lazy chapter windows, retries, and disposal.
- Run `flutter analyze` and the complete Flutter test suite before handoff.

## 11. Delivery and commit plan

1. Product requirements and implementation boundary.
2. Reader setting model plus SQLite schema migration.
3. Scroll/Pages mode and tap/swipe screen navigation.
4. Progress display, chapter actions, and catalog scrubber.
5. Live appearance sheet, palettes, typography, orientation, and responsive
   columns.
6. In-reader bookmarks and markers.
7. Verification fixes and documentation only if they form an independent
   reviewable change.

Each implementation commit must include its focused tests and leave analysis
and the relevant test subset passing.

## 12. Deferred backlog and research

- Text selection, copy, highlights, notes, in-book search, dictionary, and
  translation actions.
- On-device TTS, bilingual queues, sentence highlighting, and audio controls.
- Low-vision/dyslexia presets, a reading ruler, and formal assistive-technology
  certification.
- Active reading time, time remaining, goals, streaks, and achievements.
- True typeset pagination with text fragmentation, stable page anchors,
  illustration rules, and deterministic repagination across bilingual layouts.

# Wenku EPUB rendering audit — 2026-08-23

## Outcome

The rendering problem is not only a reader-engine problem. Novelia's bilingual EPUB generator deliberately rewrites an otherwise conventional EPUB 3 publication in ways that remove essential layout information. A capable HTML/CSS EPUB engine plus a Wenku-specific normalization layer is required.

The first implementation unpacks the EPUB in Dart and renders sanitized spine XHTML in Flutter's official system WebView, with app-owned CSS for Japanese ruby, Chinese/Japanese paragraph pairing, `tcy`, illustrations, line length, and CJK font fallback. The integration is isolated behind the Wenku reader screen so native Readium, EPUB.js, or another engine can replace it after device testing without changing the catalog/download domain.

## Representative sample

- Public, non-R18 catalog work: `RAIL WARS!` (`676c3b6c17bd541a0fec8d30`)
- Volume: `RAIL WARS! 3 日本國有鉄道公安隊.epub`
- Generated mode inspected: Japanese-first bilingual, priority translations
- Downloaded size: 7,217,826 bytes
- Archive: 52 entries — one package document, navigation document, 32 XHTML documents, 11 JPEG images, and 5 CSS resources
- Validation: all XML parsed and W3C EPUBCheck 5.3.0 reported no errors or warnings

The sample is not committed to the repository. It was downloaded temporarily from the public service solely for compatibility inspection.

## Structural findings

- All five declared CSS resources are zero bytes. Publisher classes remain in XHTML, including `vrtl`, `hltr`, `tcy`, and `fit`, but their definitions are gone.
- Package metadata declares `zh-CN` and `primary-writing-mode=horizontal-lr`; the spine has no page progression direction. Most XHTML documents still declare Japanese.
- The generator inserts translated paragraphs next to each Japanese paragraph. Japanese is identified only by `style="opacity:0.4;"`; inserted Chinese paragraphs carry neither a language tag nor a dedicated class.
- The book contains 7,506 paragraphs, including 3,722 faded Japanese paragraphs, 111 `ruby` elements, 121 `rt` elements, 253 `tcy` spans, and 11 illustrations.
- The stripped `.fit` rule leaves full-page illustrations without their original viewport constraint.
- No scripts, iframes, remote resources, audio, or video were found. All publication resources are local.
- The first ZIP entry is `mimetype`, but it is DEFLATE-compressed. EPUB 3 requires that entry to be first and stored without compression. EPUBCheck did not flag this sample, so the defect remains a compatibility risk.

## Upstream transformation

The public AutoNovel server source confirms the behavior:

- `WenkuNovelVolumeRepository.kt` clones the original EPUB, injects translation paragraphs, fades Japanese, changes package language/writing metadata, removes spine progression, and replaces every stylesheet with empty bytes.
- `Epub.kt` writes every ZIP member through `ZipOutputStream` without storing `mimetype` uncompressed.

This means a generic reader cannot recover the publisher's original vertical styles. The app's fallback deliberately respects the generated horizontal mode while restoring semantics that remain discoverable in XHTML.

## Renderer decision criteria

| Option | Strength | Blocking issue |
| --- | --- | --- |
| Flutter text widgets | Native controls and styling | Loses XHTML, ruby layout, CFI navigation, fixed-layout images, and publisher semantics |
| Readium Swift/Kotlin | Strong native EPUB navigation | Two platform bridges and no equivalent production macOS navigator |
| EPUB.js wrapper | XHTML/CSS fidelity, CFI, TOC, ruby and image support | Evaluated wrapper failed this repository's AGP 9 / Swift Package Manager platform matrix |
| App-owned system WebView host | Official native integration, XHTML/CSS fidelity, small controllable bridge | Must own EPUB unpacking and spine/progress navigation; requires physical-device QA |

Relevant primary references: [EPUB 3.3](https://www.w3.org/TR/epub-33/), [Flutter WebView](https://github.com/flutter/packages/tree/main/packages/webview_flutter/webview_flutter), [EPUB.js](https://github.com/futurepress/epub.js), [Readium Swift](https://github.com/readium/swift-toolkit), and [Readium Kotlin](https://github.com/readium/kotlin-toolkit).

## Pagination regression findings

A second real Wenku volume reproduced the reported macOS failures: a left-side tap at a chapter boundary, text touching or crossing the last-page edge, a thin strip of an illustration on the following page, and a different result after paging forward and back.

The common cause was WebKit column fragmentation, not random navigation state. A paragraph containing only a 169×1920 vertical chapter-title image became 1920px high after the publisher stylesheet was stripped. Its default paragraph margins made it span columns, producing a blank/partial visual page. Separately, WebKit omitted the final half-gap from the natural multicolumn `scrollWidth`, so treating raw maximum scroll as a page shifted only the final page.

The corrected implementation mirrors EPUB.js's layout and default-manager rules:

- the viewport width is the fixed page delta;
- logical page count is `ceil(scrollWidth / delta)` and target lookup uses `floor(offset / delta)`;
- an out-of-flow endpoint normalizes the scrollable extent to `pageCount × delta` after fonts and images settle (WKWebView does not consistently count a root `min-width` as scrollable content);
- a previous-spine transition restores the last logical page rather than a raw fraction of the old extent;
- image-only spine documents are one viewport, while image-only paragraphs and figures are one unbreakable column;
- actual window resizing preserves logical progression, while showing or hiding Reader Chrome never resizes the WebView.

Browser visual regression against the real volume confirmed that the page after the vertical chapter image and the chapter's final page both occupy the same `72px … 1208px` safe content bounds in a 1280px viewport, with no image strip or text overflow.

## Release quality gates

Before calling the reader production-ready, verify the inspected sample plus at least two books from different publishers on a physical Android phone, iPhone, and iPad. Check ruby placement, punctuation, mixed Latin digits, full-page and landscape art, TOC jumps, horizontal tap/swipe pagination, font scaling, dark mode, selection, progress restoration, memory pressure, and a 40–50 MiB volume. A failed mobile fidelity or memory gate should trigger evaluation of the native Readium adapters described in ADR 0005.

# Render Wenku EPUBs in an app-owned system WebView host

Wenku EPUBs retain publisher XHTML, ruby, SVG, illustrations, and navigation even though the service-generated bilingual files remove their stylesheets. We will unpack EPUBs in Dart and render sanitized spine documents in Flutter's official system WebView with narrowly targeted fallback CSS; flattening books into Flutter text would discard publication structure, while native Readium would require separate Android and iOS implementations and has no production macOS navigator.

The pagination implementation follows the mature EPUB.js/Readium model rather than deriving navigation from arbitrary scroll fractions: the viewport width is the fixed page delta, total pages are `ceil(content length / delta)`, target offsets are floored to a logical page, and crossing to a previous spine restores its final logical page. Font and image readiness precede locator restoration. Image-only spine resources and image-only paragraph/figure blocks receive explicit viewport constraints so WebKit cannot fragment a replaced element across two columns.

`flutter_epub_viewer` 2.0.0 was also built in an isolated spike. It wraps EPUB.js and declares macOS support, but its `flutter_inappwebview_macos` dependency does not support this repository's Swift Package Manager build and forces CocoaPods integration. Flutter currently warns about that mixed Apple package-manager state and the macOS build fails without CocoaPods, so replacing the existing component would increase build-system risk without removing the Wenku-specific normalization requirement.

## Consequences

The reader stores progress as a spine index plus logical-page progression, not as raw scroll pixels or EPUB CFI, and must be tested on real Android and Apple devices with Japanese ruby, full-page artwork, horizontal tap/swipe pagination, and font scaling. Publication scripts and inline event handlers are removed before rendering, navigation is limited to local spine resources, downloads are capped at 64 MiB, and the renderer remains isolated so Readium or EPUB.js can replace it if physical-device fidelity gates fail.

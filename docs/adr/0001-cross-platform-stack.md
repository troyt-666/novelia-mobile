# ADR 0001: Cross-platform stack

Status: **Accepted; physical performance verified**
Date: 2026-08-10

## Decision update — 2026-08-18

Continue in Flutter. Automated reader, restoration, live/cache gateway,
download, migration, account, and offline-relaunch tests are green (175 tests),
and the bounded anonymous live pass remains green. The prior JNI/Android build
issue is resolved. A profile APK installs directly on the Android 16 arm64
phone, restores the real reader, and remains near the 90 Hz display cadence
under repeated swipes and a fast drag. A Personal Team iPhone profile build
signs, installs, launches, and completes a steady-scroll native trace without a
recorded hitch, potential hang, or sampled frame lifetime above 18 ms. The
optimized macOS reader also passes synchronized rapid-scroll tracing and manual
fast-trackpad review.

The physical install and performance risk that motivated the gate is no longer
deferred. This update does not imply completion of a formal VoiceOver/TalkBack,
large-font, or device-typography matrix; those checks remain explicit release
QA. If they expose a platform-level reader failure, the fallback decision stays
available because the reader model, gateway, and database boundaries remain
independent of Flutter widgets.

## Context

The project needs Android and iOS applications maintained by a small team, with
one distinctive feature: a fast, accessible reader that treats a
Chinese translation as primary and can show its associated Japanese block
underneath for verification.
Offline reading, authentication, file sharing, and background downloads must
also respect each platform's rules.

The reference APK is Flutter, and its Android reader behavior is already known
to be acceptable. There is no reusable Dart source.

## Decision

Start with **Flutter** and make the first deliverable a fixture-backed reader
spike on physical Android and iOS devices. Do not scaffold the full application
until that spike passes its exit gate.

Use a package-neutral domain/data design so this decision is reversible:

- UI depends on view models and domain models, never raw API JSON;
- all undocumented service details live behind `NoveliaGateway`;
- platform storage, secrets, authentication, sharing, and background work are
  ports with Android/iOS implementations;
- the paired-reader model is independent of Flutter widgets.

## Why Flutter first

- One UI codebase is the lowest maintenance burden for a solo/small-team app.
- The reference app demonstrates that Flutter can deliver the desired Android
  reader interaction and rendering style.
- Android and iOS are mature supported Flutter targets.
- Flutter provides explicit locale-aware text and predictable cross-platform
  layout, which is valuable for Japanese/Chinese glyph selection.
- Native integrations can remain thin and isolated behind platform channels or
  plugins.

This choice does **not** mean copying the reference app's dependencies or
architecture. New storage, security, update, and platform integration choices
must be made for a production-quality application.

## Reader-spike exit gate

Test the same difficult fixture corpus on a mid-range Android device and a real
iPhone/iPad. Flutter remains the implementation stack only if all of these pass:

- stable semantic Japanese/Chinese pairing across widths and font scaling;
- correct Japanese and Chinese glyph forms through explicit locales;
- smooth long-chapter scrolling in release/profile builds;
- VoiceOver and TalkBack traversal in displayed language order;
- position restoration after relaunch and content revision;
- acceptable native navigation, keyboard, share sheet, and safe-area behavior.

If the iOS reader fails accessibility or typography requirements,
retain the domain/gateway/database contracts and evaluate a native SwiftUI
reader or Kotlin Multiplatform shared core. Do not force the whole product
through a failing UI abstraction.

Text selection, copying, highlights, and annotations are not v1 reader
requirements under the accepted product scope. If selection is reintroduced,
it requires a new cross-platform interaction and performance check rather than
being inferred from this decision.

## Alternatives considered

### Kotlin Multiplatform + Compose Multiplatform

Advantages:

- selective sharing rather than all-or-nothing sharing;
- stable Android/iOS Compose targets;
- shared networking, persistence, domain logic, and optionally UI;
- strong native escape hatches.

Costs:

- higher Gradle/Xcode/Kotlin-Native integration complexity;
- younger iOS text, selection, accessibility, and tooling surface;
- more operational complexity than needed before the product/API is validated.

This is the preferred fallback if the project later requires substantially more
native integration or Flutter fails the iOS reader gate.

### Separate native Kotlin and Swift applications

Advantages:

- best platform fidelity and mature native text/background APIs.

Costs:

- two reader implementations and duplicated parsing, caching, synchronization,
  migrations, and tests;
- highest ongoing maintenance burden.

Choose this only if platform-native fidelity becomes more important than shared
delivery speed.

## Primary references

- [Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)
- [Flutter architecture guide](https://docs.flutter.dev/app-architecture/guide)
- [Flutter `Text.locale`](https://api.flutter.dev/flutter/widgets/Text/locale.html)
- [Kotlin Multiplatform platform stability](https://kotlinlang.org/docs/multiplatform/supported-platforms.html)
- [Compose Multiplatform and SwiftUI integration](https://kotlinlang.org/docs/multiplatform/compose-swiftui-integration.html)

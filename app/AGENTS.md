# JFZ Reader agent guide

## Scope and safety

- This is an independent Flutter implementation. Do not copy code, assets,
  wording, credentials, or identifiers from the reference APK.
- `io.github.troyt666.jfzreader` is the permanent release identifier. Do not
  change it after distributing a signed build.
- Keep secrets out of the repository and use fixture data for agent-driven UI
  work.

## Default development loop

Use macOS as the default fast-feedback target:

```sh
flutter --no-version-check analyze
flutter --no-version-check test
flutter --no-version-check run -d macos
flutter --no-version-check build macos
```

For Android, use the Apple-silicon ARM emulator named `novelia_api36`. It runs
Android 16 (API 36); a physical Android phone is not needed for the normal
development loop. Start it from Android Studio's Device Manager, then confirm
the device ID before deployment:

```sh
flutter --no-version-check devices
flutter --no-version-check run -d emulator-5554
```

The iOS Simulator runtime is installed. For iOS-native work, open
`ios/Runner.xcworkspace` in Xcode before using Xcode's external-agent bridge.
CocoaPods is not installed yet, so add it before introducing native iOS or
macOS plugins.

## Agent-friendly UI

- Give important controls stable `ValueKey` values and descriptive `Semantics`
  labels.
- Keep state resettable and tests deterministic.
- Use the Dart MCP server for Flutter analysis, tests, runtime errors, widget
  inspection, and hot reload. Use Xcode's MCP bridge only for iOS-native work
  once its platform components are ready.
- Save a screenshot, filtered logs, and the failing test output when reporting
  an integration failure.

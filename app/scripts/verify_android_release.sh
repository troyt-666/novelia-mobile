#!/usr/bin/env bash
set -euo pipefail

release_apk="${1:-build/app/outputs/flutter-apk/app-release.apk}"
release_apksigner="${APKSIGNER:-}"

if [[ ! -f "$release_apk" ]]; then
  echo "Release APK not found: $release_apk" >&2
  exit 1
fi

if [[ -z "$release_apksigner" ]]; then
  release_apksigner="$(command -v apksigner || true)"
fi
if [[ -z "$release_apksigner" || ! -x "$release_apksigner" ]]; then
  echo "Set APKSIGNER to the Android SDK apksigner executable." >&2
  exit 1
fi

if ! release_certificate="$($release_apksigner verify --verbose --print-certs "$release_apk" 2>&1)"; then
  printf '%s\n' "$release_certificate" >&2
  echo "Release APK signature verification failed; unsigned artifacts are not distributable." >&2
  exit 1
fi
case "$release_certificate" in
  *"Android Debug"*)
    echo "Refusing a release signed with the Android Debug certificate." >&2
    exit 1
    ;;
esac

printf '%s\n' "$release_certificate"
shasum -a 256 "$release_apk"

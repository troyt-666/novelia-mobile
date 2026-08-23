#!/usr/bin/env bash
set -euo pipefail

required_variables=(
  RELEASE_TAG
  APP_VERSION
  APP_BUILD_NUMBER
  RELEASE_PUBLISHED_AT
  RELEASE_PAGE_URL
  RELEASE_NOTES_FILE
  SITE_OUTPUT_DIR
  ANDROID_APK
  IOS_IPA
  MACOS_DMG
  MACOS_SPARKLE_SIGNATURE_FILE
  GITHUB_REPOSITORY
  GITHUB_REPOSITORY_OWNER
)

for name in "${required_variables[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing update-site input: $name" >&2
    exit 1
  fi
done

for artifact in "$ANDROID_APK" "$IOS_IPA" "$MACOS_DMG"; do
  if [[ ! -s "$artifact" ]]; then
    echo "Missing release artifact: $artifact" >&2
    exit 1
  fi
done
if [[ ! -s "$MACOS_SPARKLE_SIGNATURE_FILE" ]]; then
  echo "Missing Sparkle signature: $MACOS_SPARKLE_SIGNATURE_FILE" >&2
  exit 1
fi

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid app version: $APP_VERSION" >&2
  exit 1
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid app build number: $APP_BUILD_NUMBER" >&2
  exit 1
fi
if [[ "$RELEASE_TAG" != "v${APP_VERSION}+${APP_BUILD_NUMBER}" ]]; then
  echo "Release tag does not match app version and build: $RELEASE_TAG" >&2
  exit 1
fi

repository_name="${GITHUB_REPOSITORY#*/}"
pages_base_url="https://${GITHUB_REPOSITORY_OWNER}.github.io/${repository_name}"
release_asset_base="https://github.com/${GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}"
safe_tag="${RELEASE_TAG//\//-}"
android_name="JFZ-Reader-${safe_tag}-android.apk"
ios_name="JFZ-Reader-${safe_tag}-ios-unsigned.ipa"
macos_name="JFZ-Reader-${safe_tag}-macos.dmg"
android_url="${release_asset_base}/${android_name}"
ios_url="${release_asset_base}/${ios_name}"
macos_url="${release_asset_base}/${macos_name}"

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

file_sha256() {
  sha256sum "$1" | cut -d ' ' -f 1
}

mkdir -p "$SITE_OUTPUT_DIR"
cp app/assets/branding/novelia_app_icon_v2.png "$SITE_OUTPUT_DIR/icon.png"
touch "$SITE_OUTPUT_DIR/.nojekyll"

android_size="$(file_size "$ANDROID_APK")"
ios_size="$(file_size "$IOS_IPA")"
macos_size="$(file_size "$MACOS_DMG")"
android_sha256="$(file_sha256 "$ANDROID_APK")"
ios_sha256="$(file_sha256 "$IOS_IPA")"
macos_sha256="$(file_sha256 "$MACOS_DMG")"
sparkle_signature_fragment="$(tr -d '\r\n' < "$MACOS_SPARKLE_SIGNATURE_FILE")"
if [[ ! "$sparkle_signature_fragment" =~ ^sparkle:edSignature=\"([A-Za-z0-9+/=]+)\"[[:space:]]length=\"([0-9]+)\"$ ]]; then
  echo "Invalid Sparkle signature metadata." >&2
  exit 1
fi
sparkle_ed_signature="${BASH_REMATCH[1]}"
sparkle_signed_size="${BASH_REMATCH[2]}"
if [[ "$sparkle_signed_size" != "$macos_size" ]]; then
  echo "Sparkle signature size does not match the macOS DMG." >&2
  exit 1
fi

jq -n \
  --arg version "$APP_VERSION" \
  --argjson buildNumber "$APP_BUILD_NUMBER" \
  --arg publishedAt "$RELEASE_PUBLISHED_AT" \
  --arg releasePageUrl "$RELEASE_PAGE_URL" \
  --arg altStoreSourceUrl "$pages_base_url/altstore-source.json" \
  --rawfile releaseNotes "$RELEASE_NOTES_FILE" \
  --arg androidUrl "$android_url" \
  --argjson androidSize "$android_size" \
  --arg androidSha256 "$android_sha256" \
  --arg iosUrl "$ios_url" \
  --argjson iosSize "$ios_size" \
  --arg iosSha256 "$ios_sha256" \
  --arg macosUrl "$macos_url" \
  --argjson macosSize "$macos_size" \
  --arg macosSha256 "$macos_sha256" \
  '{
    schemaVersion: 1,
    version: $version,
    buildNumber: $buildNumber,
    publishedAt: $publishedAt,
    releasePageUrl: $releasePageUrl,
    altStoreSourceUrl: $altStoreSourceUrl,
    releaseNotes: $releaseNotes[0:8000],
    downloads: {
      android: {
        url: $androidUrl,
        size: $androidSize,
        sha256: $androidSha256
      },
      ios: {
        url: $iosUrl,
        size: $iosSize,
        sha256: $iosSha256
      },
      macos: {
        url: $macosUrl,
        size: $macosSize,
        sha256: $macosSha256
      }
    }
  }' > "$SITE_OUTPUT_DIR/latest.json"

release_page_xml="$(jq -rn --arg value "$RELEASE_PAGE_URL" '$value | @html')"
release_notes_xml="$(jq -Rs -r '@html' "$RELEASE_NOTES_FILE")"
macos_url_xml="$(jq -rn --arg value "$macos_url" '$value | @html')"
if published_at_rfc2822="$(date --date="$RELEASE_PUBLISHED_AT" --rfc-email 2>/dev/null)"; then
  :
else
  published_at_rfc2822="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$RELEASE_PUBLISHED_AT" '+%a, %d %b %Y %H:%M:%S +0000')"
fi
cat > "$SITE_OUTPUT_DIR/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>JFZ Reader macOS updates</title>
    <link>$release_page_xml</link>
    <description>Signed JFZ Reader updates for macOS.</description>
    <language>zh-CN</language>
    <item>
      <title>JFZ Reader $APP_VERSION</title>
      <link>$release_page_xml</link>
      <sparkle:version>$APP_BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>10.15.0</sparkle:minimumSystemVersion>
      <pubDate>$published_at_rfc2822</pubDate>
      <description sparkle:format="plain-text">$release_notes_xml</description>
      <enclosure url="$macos_url_xml"
        sparkle:edSignature="$sparkle_ed_signature"
        length="$macos_size"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

jq -n \
  --arg website "https://github.com/${GITHUB_REPOSITORY}" \
  --arg iconUrl "$pages_base_url/icon.png" \
  --arg version "$APP_VERSION" \
  --arg buildVersion "$APP_BUILD_NUMBER" \
  --arg publishedAt "$RELEASE_PUBLISHED_AT" \
  --rawfile releaseNotes "$RELEASE_NOTES_FILE" \
  --arg iosUrl "$ios_url" \
  --argjson iosSize "$ios_size" \
  --arg iosSha256 "$ios_sha256" \
  '{
    name: "JFZ Reader",
    subtitle: "Novelia-compatible bilingual offline reader",
    description: "Official JFZ Reader releases for AltStore Classic.",
    iconURL: $iconUrl,
    website: $website,
    tintColor: "#6750A4",
    featuredApps: ["io.github.troyt666.jfzreader"],
    apps: [
      {
        name: "JFZ Reader",
        bundleIdentifier: "io.github.troyt666.jfzreader",
        developerName: "JFZ Reader Contributors",
        subtitle: "Chinese-first bilingual offline reader",
        localizedDescription: "Read supported web novels with Chinese translations, Japanese originals, and protected offline downloads.",
        iconURL: $iconUrl,
        tintColor: "#6750A4",
        category: "entertainment",
        screenshots: [],
        versions: [
          {
            version: $version,
            buildVersion: $buildVersion,
            date: $publishedAt,
            localizedDescription: $releaseNotes[0:8000],
            downloadURL: $iosUrl,
            size: $iosSize,
            sha256: $iosSha256,
            minOSVersion: "13.0"
          }
        ],
        appPermissions: {
          entitlements: [],
          privacy: {}
        }
      }
    ],
    news: []
  }' > "$SITE_OUTPUT_DIR/altstore-source.json"

jq empty "$SITE_OUTPUT_DIR/latest.json"
jq empty "$SITE_OUTPUT_DIR/altstore-source.json"
grep -q '<sparkle:version>' "$SITE_OUTPUT_DIR/appcast.xml"

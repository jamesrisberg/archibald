#!/usr/bin/env bash
set -euo pipefail

APP_NAME="archibald"
PROJECT_PATH="archibald/archibald.xcodeproj"
SCHEME="archibald"
APPCAST_PATH="appcast.xml"
GITHUB_REPO="jamesrisberg/archibald"

BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/Archibald.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
DMG_PATH="${BUILD_DIR}/Archibald.dmg"

NOTARIZE="${NOTARIZE:-1}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing env: ${name}" >&2
    exit 1
  fi
}

require_tool() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing tool: ${name}" >&2
    exit 1
  fi
}

require_tool xcodebuild
require_tool hdiutil
require_tool xcrun
require_tool gh

require_env APPLE_TEAM_ID

if [[ "${NOTARIZE}" == "1" ]]; then
  require_env APPLE_ID
  require_env APPLE_APP_SPECIFIC_PASSWORD
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Archiving"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -destination 'generic/platform=macOS' \
  archive

echo "==> Exporting"
cat > "${BUILD_DIR}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
EOF

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
  -exportPath "${EXPORT_PATH}"

APP_PATH="$(find "${EXPORT_PATH}" -maxdepth 1 -name "*.app" | head -n 1)"
if [[ -z "${APP_PATH}" ]]; then
  echo "Export failed: no .app found in ${EXPORT_PATH}" >&2
  exit 1
fi

# Extract version info from built app
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${INFO_PLIST}")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${INFO_PLIST}")
echo "==> Version: ${VERSION} (${BUILD_NUMBER})"

echo "==> Creating DMG"
mkdir -p "${BUILD_DIR}/dmg"
rm -rf "${BUILD_DIR}/dmg/Archibald.app"
cp -R "${APP_PATH}" "${BUILD_DIR}/dmg/Archibald.app"
hdiutil create -volname "Archibald" -srcfolder "${BUILD_DIR}/dmg" -ov -format UDZO "${DMG_PATH}"

if [[ "${NOTARIZE}" == "1" ]]; then
  echo "==> Notarizing"
  xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID}" \
    --wait

  echo "==> Stapling"
  xcrun stapler staple "${DMG_PATH}"
else
  echo "==> Skipping notarization (NOTARIZE=0)"
fi

# Get file size
DMG_SIZE=$(stat -f%z "${DMG_PATH}")

# Find sign_update tool and generate signature
echo "==> Generating Sparkle signature"
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -n 1)
if [[ -z "${SIGN_UPDATE}" ]]; then
  echo "Error: sign_update tool not found in DerivedData." >&2
  echo "Build the project in Xcode first, or download Sparkle tools from:" >&2
  echo "  https://github.com/sparkle-project/Sparkle/releases" >&2
  exit 1
fi

# Use archibald-specific signing key
SPARKLE_SIG=$("${SIGN_UPDATE}" "${DMG_PATH}" --account archibald | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
echo "Signature: ${SPARKLE_SIG:0:20}..."

# Create GitHub release and upload DMG
TAG="v${VERSION}"
echo "==> Creating GitHub release ${TAG}"
if gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
  echo "Release ${TAG} already exists, uploading DMG..."
  gh release upload "${TAG}" "${DMG_PATH}" --repo "${GITHUB_REPO}" --clobber
else
  gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "Archibald ${VERSION}" \
    --notes "Release ${VERSION}" \
    --draft
  echo "Created draft release. Edit and publish at:"
  echo "  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
fi

# Update appcast.xml
echo "==> Updating appcast.xml"
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/Archibald.dmg"

# Create new item entry
NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version ${VERSION}</title>
      <description><![CDATA[
        <h2>What's New in ${VERSION}</h2>
        <ul>
          <li>Update release notes here</li>
        </ul>
      ]]></description>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${SPARKLE_SIG}"
        length="${DMG_SIZE}"
        type="application/octet-stream"/>
    </item>
EOF
)

# Insert new item after <language>en</language> line
if [[ -f "${APPCAST_PATH}" ]]; then
  # Check if this version already exists in appcast
  if grep -q "sparkle:version>${BUILD_NUMBER}<" "${APPCAST_PATH}"; then
    echo "Warning: Version ${BUILD_NUMBER} already in appcast.xml, updating in place..."
    # Remove old entry for this version and add new one
    # This is a simple approach - for production you might want something more robust
    awk -v new_item="${NEW_ITEM}" -v build="${BUILD_NUMBER}" '
      /<item>/ { in_item=1; item_buf=$0; next }
      in_item && /<\/item>/ {
        item_buf=item_buf ORS $0
        if (item_buf ~ "sparkle:version>" build "<") {
          print new_item
        } else {
          print item_buf
        }
        in_item=0; item_buf=""
        next
      }
      in_item { item_buf=item_buf ORS $0; next }
      { print }
    ' "${APPCAST_PATH}" > "${APPCAST_PATH}.tmp" && mv "${APPCAST_PATH}.tmp" "${APPCAST_PATH}"
  else
    # Insert new item at the top (after the comment line)
    awk -v new_item="${NEW_ITEM}" '
      /<!-- Add new versions at the top -->/ { print; print new_item; next }
      { print }
    ' "${APPCAST_PATH}" > "${APPCAST_PATH}.tmp" && mv "${APPCAST_PATH}.tmp" "${APPCAST_PATH}"
  fi
else
  echo "Error: ${APPCAST_PATH} not found" >&2
  exit 1
fi

echo ""
echo "==> Done!"
echo ""
echo "Build:    ${DMG_PATH}"
echo "Version:  ${VERSION} (${BUILD_NUMBER})"
echo "Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "Next steps:"
echo "  1. Edit release notes in appcast.xml"
echo "  2. Commit and push appcast.xml"
echo "  3. Publish the GitHub release (if draft)"

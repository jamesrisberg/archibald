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
ZIP_PATH="${BUILD_DIR}/Archibald.zip"

NOTARIZE="${NOTARIZE:-1}"

# Load env vars from .env if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

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
require_tool ditto
require_tool zip
require_tool xcrun
require_tool gh

require_env APPLE_TEAM_ID

if [[ "${NOTARIZE}" == "1" ]]; then
  require_env APPLE_ID
  require_env APPLE_APP_SPECIFIC_PASSWORD
fi

PROJECT_PBXPROJ="${PROJECT_PATH}/project.pbxproj"
if [[ ! -f "${PROJECT_PBXPROJ}" ]]; then
  echo "Error: ${PROJECT_PBXPROJ} not found" >&2
  exit 1
fi

CURRENT_VERSION=$(
  xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration Release -showBuildSettings \
    | awk -F ' = ' '/MARKETING_VERSION/ { print $2; exit }'
)
if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "Error: Unable to read MARKETING_VERSION from build settings." >&2
  exit 1
fi
CURRENT_BUILD_NUMBER=$(
  xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration Release -showBuildSettings \
    | awk -F ' = ' '/CURRENT_PROJECT_VERSION/ { print $2; exit }'
)
if [[ -z "${CURRENT_BUILD_NUMBER}" ]]; then
  echo "Error: Unable to read CURRENT_PROJECT_VERSION from build settings." >&2
  exit 1
fi
if ! [[ "${CURRENT_BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "Error: CURRENT_PROJECT_VERSION is not numeric: ${CURRENT_BUILD_NUMBER}" >&2
  exit 1
fi
NEXT_BUILD_NUMBER=$((CURRENT_BUILD_NUMBER + 1))
echo "Current project version: ${CURRENT_VERSION}"
echo "Current build number: ${CURRENT_BUILD_NUMBER} -> ${NEXT_BUILD_NUMBER}"
read -r -p "Enter release version (e.g. ${CURRENT_VERSION}): " RELEASE_VERSION
if [[ -z "${RELEASE_VERSION}" ]]; then
  echo "Error: Release version is required." >&2
  exit 1
fi
if [[ "${RELEASE_VERSION}" != "${CURRENT_VERSION}" ]]; then
  echo "Updating project version to ${RELEASE_VERSION}"
  perl -0pi -e "s/(MARKETING_VERSION = )[^;]+;/\${1}${RELEASE_VERSION};/g" "${PROJECT_PBXPROJ}"
fi
echo "Incrementing build number to ${NEXT_BUILD_NUMBER}"
perl -0pi -e "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\${1}${NEXT_BUILD_NUMBER};/g" "${PROJECT_PBXPROJ}"

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
if [[ "${VERSION}" != "${RELEASE_VERSION}" ]]; then
  echo "Error: Built app version (${VERSION}) does not match requested version (${RELEASE_VERSION})." >&2
  exit 1
fi

if [[ "${NOTARIZE}" == "1" ]]; then
  echo "==> Zipping app for notarization"
  NOTARIZE_ZIP="${BUILD_DIR}/Archibald-notarize.zip"
  rm -f "${NOTARIZE_ZIP}"
  ditto -c -k --keepParent "${APP_PATH}" "${NOTARIZE_ZIP}"

  echo "==> Notarizing"
  xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID}" \
    --wait

  echo "==> Stapling .app bundle"
  xcrun stapler staple "${APP_PATH}"
else
  echo "==> Skipping notarization (NOTARIZE=0)"
fi

echo "==> Creating distribution ZIP"
# Important: use /usr/bin/zip -X (skip extended attributes / resource forks)
# rather than `ditto -c -k --keepParent`. ditto bakes xattrs as `._*`
# AppleDouble entries inside the zip — when extracted by anything other than
# `ditto -x -k` (Safari, Archive Utility on Tahoe, Sparkle's installer), those
# expand into real files inside the bundle and corrupt the codesign
# ("could not verify it's not malware" on launch).
rm -f "${ZIP_PATH}"
ZIP_ABS_PATH="$(cd "$(dirname "${ZIP_PATH}")" && pwd)/$(basename "${ZIP_PATH}")"
APP_PARENT_DIR="$(cd "$(dirname "${APP_PATH}")" && pwd)"
APP_BASENAME="$(basename "${APP_PATH}")"
( cd "${APP_PARENT_DIR}" && /usr/bin/zip --symlinks --recurse-paths -X -q "${ZIP_ABS_PATH}" "${APP_BASENAME}" )

# Get file size
DMG_SIZE=$(stat -f%z "${ZIP_PATH}")

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
SPARKLE_SIG=$("${SIGN_UPDATE}" "${ZIP_PATH}" --account archibald | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
echo "Signature: ${SPARKLE_SIG:0:20}..."

# Create GitHub release and upload ZIP
TAG="v${VERSION}"
echo "==> Creating GitHub release ${TAG}"
if gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
  echo "Release ${TAG} already exists, uploading ZIP..."
  gh release upload "${TAG}" "${ZIP_PATH}" --repo "${GITHUB_REPO}" --clobber
else
  gh release create "${TAG}" "${ZIP_PATH}" \
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
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/Archibald.zip"

# Create new item entry
NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version ${VERSION}</title>
      <description><![CDATA[
        <h2>What&apos;s New in ${VERSION}</h2>
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
NEW_ITEM_FILE="${BUILD_DIR}/appcast-item.xml"
printf "%s" "${NEW_ITEM}" > "${NEW_ITEM_FILE}"

# Insert new item after <language>en</language> line
if [[ -f "${APPCAST_PATH}" ]]; then
  # Insert new item at the top (after the comment line)
  if grep -q "sparkle:version>${BUILD_NUMBER}<" "${APPCAST_PATH}" || grep -q "sparkle:shortVersionString>${VERSION}<" "${APPCAST_PATH}"; then
    echo "Warning: Version ${VERSION} already in appcast.xml; adding another entry at the top."
  fi
  awk -v new_item_file="${NEW_ITEM_FILE}" '
    BEGIN {
      new_item = ""
      while ((getline line < new_item_file) > 0) { new_item = new_item line ORS }
      close(new_item_file)
    }
    /<!-- Add new versions at the top -->/ { print; printf "%s", new_item; next }
    { print }
  ' "${APPCAST_PATH}" > "${APPCAST_PATH}.tmp"
  if ! cmp -s "${APPCAST_PATH}" "${APPCAST_PATH}.tmp"; then
    mv "${APPCAST_PATH}.tmp" "${APPCAST_PATH}"
  else
    # Fallback: insert after <language> if comment marker missing
    awk -v new_item_file="${NEW_ITEM_FILE}" '
      BEGIN {
        new_item = ""
        while ((getline line < new_item_file) > 0) { new_item = new_item line ORS }
        close(new_item_file)
      }
      /<language>en<\/language>/ { print; printf "%s", new_item; next }
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
echo "Build:    ${ZIP_PATH}"
echo "Version:  ${VERSION} (${BUILD_NUMBER})"
echo "Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "Next steps:"
echo "  1. Edit release notes in appcast.xml"
echo "  2. Commit and push appcast.xml"
echo "  3. Publish the GitHub release (if draft)"

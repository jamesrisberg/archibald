#!/usr/bin/env bash
set -euo pipefail

APP_NAME="archibald"
PROJECT_PATH="archibald/archibald.xcodeproj"
SCHEME="archibald"

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

echo "Done: ${DMG_PATH}"

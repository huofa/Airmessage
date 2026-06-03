#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Airmessage"
VERSION="0.1.5"
VOLUME_NAME="${APP_NAME} ${VERSION}"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
DMG_ROOT="${BUILD_DIR}/dmg-root"
RW_DMG="${BUILD_DIR}/${APP_NAME}-${VERSION}-rw.dmg"
FINAL_DMG="${APP_NAME}-${VERSION}.dmg"

./build_app.sh

rm -rf "$DMG_ROOT" "$RW_DMG" "$FINAL_DMG"
mkdir -p "$DMG_ROOT"

cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG" >/dev/null

rm -f "$RW_DMG"

echo "$FINAL_DMG"

#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/build.local.env" ]]; then
  source "$SCRIPT_DIR/build.local.env"
fi

APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-AhaKey Studio}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-AhaKey Studio}"
OUTPUT_DIR="${OUTPUT_DIR:-$APP_ROOT/dist}"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-AhaKey Studio Installer}"
DMG_BASENAME="${DMG_BASENAME:-AhaKey-Studio-macOS-prod-$(date +%Y%m%d%H%M%S)}"
DMG_PATH="$OUTPUT_DIR/$DMG_BASENAME.dmg"
DMG_STAGING_DIR="$OUTPUT_DIR/.dmg-staging"
RW_DMG_PATH="$OUTPUT_DIR/$DMG_BASENAME-rw.dmg"
DMG_MOUNTPOINT="/Volumes/$DMG_VOLUME_NAME"
APP_BUNDLE_PATH="$OUTPUT_DIR/$APP_BUNDLE_NAME.app"
BACKGROUND_DIR="$DMG_STAGING_DIR/.background"
BACKGROUND_IMAGE="$BACKGROUND_DIR/InstallerBackground.png"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGNING_IDENTITY_HINT="${SIGNING_IDENTITY_HINT:-}"
RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-0}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ -n "$SIGNING_IDENTITY_HINT" ]]; then
    SIGNING_IDENTITY="$(echo "$IDENTITIES" | grep 'Developer ID Application' | grep "$SIGNING_IDENTITY_HINT" | head -n 1 | sed -E 's/.*"(.+)"/\1/' || true)"
  else
    SIGNING_IDENTITY="$(echo "$IDENTITIES" | grep 'Developer ID Application' | head -n 1 | sed -E 's/.*"(.+)"/\1/' || true)"
  fi
fi

echo "📦 Packaging $APP_DISPLAY_NAME DMG..."

if [[ "$RELEASE_DISTRIBUTION" == "1" ]]; then
  REQUIRE_DEVELOPER_ID=1 "$SCRIPT_DIR/build.sh"
else
  "$SCRIPT_DIR/build.sh"
fi

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "App bundle not found at $APP_BUNDLE_PATH"
  exit 1
fi

rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"

echo "🧱 Preparing DMG staging folder..."
ditto "$APP_BUNDLE_PATH" "$DMG_STAGING_DIR/$APP_BUNDLE_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
mkdir -p "$BACKGROUND_DIR"
swift "$APP_ROOT/scripts/generate_dmg_background.swift" "$BACKGROUND_IMAGE"

rm -f "$DMG_PATH" "$RW_DMG_PATH"
if [[ -d "$DMG_MOUNTPOINT" ]]; then
  hdiutil detach "$DMG_MOUNTPOINT" -force >/dev/null 2>&1 || true
fi

echo "💽 Creating writable HFS+ DMG..."
# macOS 13+ 에서는 APFS DMG의 Finder 메타데이터 유지가 불안정하므로 HFS+를 강제한다.
# macOS 26부터 hdiutil create -srcfolder 는 서명된 .app이 포함된 디렉터리를 처리할 수 없다(EPERM).
# 따라서 방식 변경: 빈 DMG 생성 → 마운트 → ditto로 파일 복사 → AppleScript 레이아웃 적용.
APP_SIZE_MB=$(du -sm "$APP_BUNDLE_PATH" | awk '{print $1}')
DMG_SIZE_MB=$(( APP_SIZE_MB + 32 ))

rm -f "$RW_DMG_PATH"
hdiutil create \
  -volname "$DMG_VOLUME_NAME" \
  -size "${DMG_SIZE_MB}m" \
  -ov \
  -fs HFS+ \
  "$RW_DMG_PATH"

echo "🪟 Applying drag-to-install layout..."
# 핵심: -noautoopen 을 쓰지 말 것. 그러면 Finder가 이 볼륨을 visible volume list에 추가하지 않아,
# 이후 AppleScript의 `tell disk "..."` 가 곧바로 -1728 (object not found)로 실패한다.
hdiutil attach "$RW_DMG_PATH" -mountpoint "$DMG_MOUNTPOINT" -readwrite -noverify

# 마운트된 볼륨에 파일을 복사한다(-srcfolder 의 EPERM 제약을 피하기 위함).
ditto "$APP_BUNDLE_PATH" "$DMG_MOUNTPOINT/$APP_BUNDLE_NAME.app"
ln -sf /Applications "$DMG_MOUNTPOINT/Applications"
mkdir -p "$DMG_MOUNTPOINT/.background"
cp "$BACKGROUND_IMAGE" "$DMG_MOUNTPOINT/.background/InstallerBackground.png"

# .background 를 숨겨서 사용자가 Finder에서 이 디렉터리를 보지 못하게 한다.
chflags hidden "$DMG_MOUNTPOINT/.background" 2>/dev/null || true

# Finder가 볼륨을 내부 list에 추가할 시간을 조금 준다.
sleep 3

set +e
osascript 2>&1 <<APPLESCRIPT
tell application "Finder"
  activate
  delay 1
  tell disk "$DMG_VOLUME_NAME"
    open
    delay 3
    try
      set current view of container window to icon view
    end try
    try
      set toolbar visible of container window to false
    end try
    try
      set statusbar visible of container window to false
    end try
    try
      set the bounds of container window to {200, 160, 1060, 640}
    end try
    try
      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 128
      set text size of theViewOptions to 13
    end try
    try
      set background picture of theViewOptions to file ".background:InstallerBackground.png"
    on error errMsg
      log "background-picture error: " & errMsg
    end try
    try
      set position of item "$APP_BUNDLE_NAME.app" of container window to {200, 240}
    end try
    try
      set position of item "Applications" of container window to {660, 240}
    end try
    update without registering applications
    delay 2
    close
    delay 1
    open
    delay 1
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
ASCRIPT_RC=$?
set -e
echo "(osascript exit=$ASCRIPT_RC)"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "🔏 Re-signing mounted app after Finder layout with: $SIGNING_IDENTITY"
  MOUNTED_APP="$DMG_MOUNTPOINT/$APP_BUNDLE_NAME.app"
  MOUNTED_AGENT="$MOUNTED_APP/Contents/MacOS/ahakeyconfig-agent"
  ENTITLEMENTS="$APP_ROOT/.build/AhaKeyConfig.entitlements"
  xattr -cr "$MOUNTED_APP" 2>/dev/null || true
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$MOUNTED_AGENT"
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$MOUNTED_APP"
  else
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$MOUNTED_APP"
    echo "⚠️  Entitlements file not found at $ENTITLEMENTS — signed without entitlements."
  fi
  codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
fi

# 메타데이터를 디스크에 강제로 기록한 뒤, .DS_Store 가 실제로 쓰였는지 검증한다.
sync; sync; sync
sleep 3
if [[ -f "$DMG_MOUNTPOINT/.DS_Store" ]]; then
  echo "✅ .DS_Store written ($(stat -f%z "$DMG_MOUNTPOINT/.DS_Store") bytes) — installer layout will persist."
else
  echo "⚠️ .DS_Store missing — Finder customization didn't persist. System Settings > Privacy > Automation 에서 Terminal에 Finder 권한을 부여했는지 확인하세요."
fi

hdiutil detach "$DMG_MOUNTPOINT" -force

echo "🗜️ Converting DMG..."
hdiutil convert "$RW_DMG_PATH" -ov -format UDZO -o "$DMG_PATH"
rm -f "$RW_DMG_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "🔏 Signing DMG with: $SIGNING_IDENTITY"
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "🧾 Notarizing DMG with profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
elif [[ "$RELEASE_DISTRIBUTION" == "1" ]]; then
  echo "❌ RELEASE_DISTRIBUTION=1 requires NOTARY_PROFILE."
  echo "   Create one with: xcrun notarytool store-credentials <profile-name> ..."
  exit 1
fi

echo "🔎 Verifying DMG..."
hdiutil verify "$DMG_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "🔎 Assessing signed artifacts..."
  spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
fi

echo "✅ DMG ready: $DMG_PATH"

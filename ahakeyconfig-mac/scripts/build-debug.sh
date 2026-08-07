#!/bin/zsh
# 빠른 debug 빌드 → 산출물을 곧바로 dist/AhaKey Studio.app에 넣습니다
# Xcode Scheme Pre-action용으로, 매번 Cmd+R 전에 .app 안의 바이너리를 자동 갱신합니다.
# 111
# 핵심 포인트:
# 1. icon, Info.plist, entitlements를 다시 생성하지 않음(이미 있으면 재사용) — 시간 절약
# 2. .app 경로, Bundle ID, entitlements 세 가지를 유지해야 TCC 권한 항목이 매칭됨
# 3. AHAKEY_DEBUG_SIGNING_IDENTITY 환경 변수로 지정한 서명 신원을 우선 사용(자체 서명 인증서 권장)
#    없으면 ad-hoc으로 fall back; ad-hoc인 경우 코드를 고치면 TCC 재승인이 필요할 수 있음

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EXECUTABLE_NAME="AhaKeyConfig"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-AhaKey Studio (디버그)}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-AhaKey Studio (디버그)}"
APP_IDENTIFIER="lab.jawa.ahakeyconfig.debug"
OUTPUT_DIR="${OUTPUT_DIR:-$APP_ROOT/dist}"
APP_BUNDLE="$OUTPUT_DIR/$APP_BUNDLE_NAME.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
AGENT_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/ahakeyconfig-agent"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ENTITLEMENTS="$APP_ROOT/.build/AhaKeyConfig.entitlements"
ICON_SOURCE="${ICON_SOURCE:-$APP_ROOT/VibeCodeKeyboard.ico}"
ICONSET_DIR="$APP_ROOT/.build/AhaKeyConfig.iconset"
ICNS_PATH="$APP_ROOT/.build/AhaKeyConfig.icns"
SIGNING_IDENTITY="${AHAKEY_DEBUG_SIGNING_IDENTITY:-${SIGNING_IDENTITY:-}}"

# 로컬 Debug는 기본적으로 안정적인 자체 서명 인증서를 사용합니다: TCC는 인증서 CN 기준으로 권한을 기억하므로
# ad-hoc 서명이 매 빌드마다 cdhash 변화로 권한을 잃는 문제를 피할 수 있습니다.
# AHAKEY_DEBUG_ADHOC=1을 명시적으로 설정하면 강제로 ad-hoc으로 되돌립니다(서명 문제 디버그용).
if [[ -z "$SIGNING_IDENTITY" ]] && [[ "${AHAKEY_DEBUG_ADHOC:-0}" != "1" ]]; then
  if [[ -x "$SCRIPT_DIR/ensure-dev-signing.sh" ]]; then
    if auto_identity="$("$SCRIPT_DIR/ensure-dev-signing.sh")"; then
      SIGNING_IDENTITY="$auto_identity"
    else
      echo "⚠️  ensure-dev-signing.sh 실패, ad-hoc 서명으로 fall back합니다"
    fi
  fi
fi

echo "🐞 Debug building $APP_DISPLAY_NAME..."
cd "$APP_ROOT"
swift build -c debug --arch arm64 --product AhaKeyConfig
swift build -c debug --arch arm64 --product ahakeyconfig-agent

BUILD_OUTPUT=".build/arm64-apple-macosx/debug/$EXECUTABLE_NAME"
AGENT_OUTPUT=".build/arm64-apple-macosx/debug/ahakeyconfig-agent"
if [[ ! -f "$BUILD_OUTPUT" ]]; then
  echo "Build output not found at $BUILD_OUTPUT"
  exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$OUTPUT_DIR"

# 기본 OLED 애니메이션 내장: 사용자가 커스터마이즈하지 않았을 때 AhaKeyOLEDDraft의 공장 기본 미리보기/업로드 소재로 사용됩니다.
# Contents/Resources/DefaultOLED/에 넣고, 코드에서 Bundle.main으로 접근합니다.
if [[ -d "$APP_ROOT/Resources/DefaultOLED" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/DefaultOLED"
  # --delete는 삭제/이름 변경된 리소스도 동기화되도록 보장합니다. 동시에 macOS 숨김 파일이 bundle에 섞이지 않도록 제외합니다.
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude='.DS_Store' --exclude='._*' --exclude='.*.swp' \
      "$APP_ROOT/Resources/DefaultOLED/" \
      "$APP_BUNDLE/Contents/Resources/DefaultOLED/"
  else
    rm -rf "$APP_BUNDLE/Contents/Resources/DefaultOLED"
    mkdir -p "$APP_BUNDLE/Contents/Resources/DefaultOLED"
    find "$APP_ROOT/Resources/DefaultOLED" -type f \
      ! -name '.DS_Store' ! -name '._*' ! -name '.*.swp' \
      -exec cp {} "$APP_BUNDLE/Contents/Resources/DefaultOLED/" \;
  fi
fi

# icon: 없을 때만 생성해서 매번 Run마다 iconutil을 다시 돌리는 것을 방지합니다
if [[ ! -f "$APP_BUNDLE/Contents/Resources/AhaKeyConfig.icns" ]]; then
  echo "🎨 Generating app icon (first run)..."
  if [[ -f "$ICON_SOURCE" ]]; then
    swift "$APP_ROOT/scripts/generate_icons.swift" "$ICONSET_DIR" "$ICON_SOURCE"
  else
    swift "$APP_ROOT/scripts/generate_icons.swift" "$ICONSET_DIR"
  fi
  iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
  cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AhaKeyConfig.icns"
fi

BUILD_NUMBER="$(git -C "$APP_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# Info.plist: 없거나 identifier가 다를 때만 다시 씁니다. Bundle ID를 일정하게 유지 → TCC 항목 안정화
NEED_PLIST=1
if [[ -f "$INFO_PLIST" ]] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null | grep -qx "$APP_IDENTIFIER"; then
  NEED_PLIST=0
fi
if [[ "$NEED_PLIST" == "1" ]]; then
  cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AhaKeyConfig</string>
  <key>CFBundleName</key>
  <string>${APP_DISPLAY_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0-debug</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>AhaKey 설정이 블루투스로 AhaKey 키보드에 연결하려면 블루투스 권한이 필요합니다.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>AhaKey Studio가 Apple 네이티브 음성 받아쓰기를 사용하려면 마이크 접근 권한이 필요합니다.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>AhaKey Studio가 음성 키를 Apple 네이티브 받아쓰기로 변환하려면 음성 인식 권한이 필요합니다.</string>
</dict>
</plist>
PLIST
fi

mkdir -p "$(dirname "$ENTITLEMENTS")"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  cat > "$ENTITLEMENTS" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.bluetooth</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS
fi

cp "$BUILD_OUTPUT" "$APP_EXECUTABLE"
cp "$AGENT_OUTPUT" "$AGENT_EXECUTABLE"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  # 40자리 16진수(SHA-1)라면 security로 CN을 역조회해 로그에서 찾기 쉽게 합니다
  if [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    IDENTITY_CN="$(security find-identity -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
      | awk -v sha="$SIGNING_IDENTITY" '$2 == sha { sub(/.*"/,""); sub(/".*/,""); print; exit }')"
    echo "🔏 Debug signing with: $SIGNING_IDENTITY${IDENTITY_CN:+ ($IDENTITY_CN)}"
  else
    echo "🔏 Debug signing with: $SIGNING_IDENTITY"
  fi
  codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_EXECUTABLE"
  codesign --force --sign "$SIGNING_IDENTITY" "$AGENT_EXECUTABLE"
  codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
else
  echo "🧪 Ad-hoc signing (TCC may need re-grant after code changes)."
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_EXECUTABLE"
  codesign --force --sign - "$AGENT_EXECUTABLE"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi

# 모든 com.apple.quarantine 확장 속성을 제거합니다
# 그렇지 않으면 ad-hoc 서명 + quarantine이 Gatekeeper App Translocation을 유발합니다:
# macOS가 .app을 /private/var/folders/.../AppTranslocation/<임의 UUID>/로 복사한 뒤 실행하는데,
# 실행할 때마다 경로가 달라져 TCC 권한이 영원히 매칭되지 않고 "입력 모니터링/손쉬운 사용"이 영원히 인식되지 않습니다.
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

# LaunchServices를 강제로 새로고침해 macOS가 오래된 bundle 메타데이터를 캐시하는 것을 방지합니다
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "✅ Debug bundle ready: $APP_BUNDLE"

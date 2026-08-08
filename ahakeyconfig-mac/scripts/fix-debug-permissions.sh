#!/bin/zsh
# 로컬 개발 전용: Debug 빌드의 TCC 권한 실효를 원클릭으로 복구합니다.
#
# 동작:
#   1. 로컬 자체 서명 인증서가 있는지 확인(ensure-dev-signing.sh)
#   2. 해당 인증서로 dist/AhaKey Studio.app 안의 모든 바이너리를 재서명
#   3. AhaKey Studio 관련 TCC 권한 항목을 초기화
#
# 이렇게 하면 사용자가 다음에 App을 실행할 때:
#   - cdhash가 바뀌어도 상관없이 TCC가 인증서 CN 기준으로 다시 인식
#   - 시스템이 권한 창을 띄우며, 한 번 체크하면 영구 적용
#
# 사용법:
#   - App 안의 "개발 버전: 서명 & 권한 복구" 버튼을 누르면 자동으로 호출됩니다
#   - 직접 실행할 수도 있습니다: scripts/fix-debug-permissions.sh
#
# 참고: scripts/build.sh(release 과정)에는 영향이 없습니다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-AhaKey Studio}"
APP_BUNDLE="$APP_ROOT/dist/$APP_BUNDLE_NAME.app"
APP_IDENTIFIER="${APP_IDENTIFIER:-lab.jawa.ahakeyconfig}"
ENTITLEMENTS="$APP_ROOT/.build/AhaKeyConfig.entitlements"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "❌ $APP_BUNDLE 을(를) 찾을 수 없습니다"
  echo "   먼저 scripts/build-debug.sh를 실행하거나 Xcode로 한 번 빌드해 주세요."
  exit 1
fi

echo "🔐 단계 1/3  로컬 자체 서명 인증서 가져오기/생성"
IDENTITY="$("$SCRIPT_DIR/ensure-dev-signing.sh")"
echo "   사용 인증서: $IDENTITY"

echo "🔏 단계 2/3  해당 인증서로 $APP_BUNDLE 재서명"

APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/AhaKeyConfig"
AGENT_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/ahakeyconfig-agent"

if [[ -f "$AGENT_EXECUTABLE" ]]; then
  codesign --force --sign "$IDENTITY" "$AGENT_EXECUTABLE"
fi

if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_EXECUTABLE"
  codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
else
  codesign --force --sign "$IDENTITY" "$APP_EXECUTABLE"
  codesign --force --sign "$IDENTITY" "$APP_BUNDLE"
fi

xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "🧹 단계 3/3  $APP_IDENTIFIER 의 TCC 권한 초기화"

# Bluetooth는 bundle id 단위 초기화를 지원하지 않으므로 건너뜁니다
for svc in ListenEvent Accessibility PostEvent Microphone SpeechRecognition; do
  if tccutil reset "$svc" "$APP_IDENTIFIER" >/dev/null 2>&1; then
    echo "   ✓ reset $svc"
  else
    echo "   - skip $svc (기존 항목 없음)"
  fi
done

echo ""
echo "✅ 복구 완료."
echo "   다음 단계: AhaKey Studio를 종료한 뒤 다시 실행하고, 시스템 안내에 따라 권한을 다시 체크하면 됩니다."
echo "   이후 코드를 고치고 다시 빌드해도 TCC가 인증서 CN 기준으로 권한을 기억하므로 다시 잃지 않습니다."

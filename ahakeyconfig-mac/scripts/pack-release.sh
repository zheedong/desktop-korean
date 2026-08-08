#!/bin/zsh
# 배포 가능한 설치 패키지(Developer ID + 공증): 내부 테스트와 외부 릴리스에 동일한 절차를 사용한다.
# 「빠른 로컬 디버그, 공증 생략」이 필요하면 바로: zsh scripts/build.sh
#
# 내부적으로 package_dmg.sh, build.sh를 호출한다.
#
# 산출물: dist/AhaKey Studio.app
#         dist/AhaKey-Studio-macOS-prod-YYYYMMDDHHmmss.dmg (DMG_BASENAME으로 덮어쓸 수 있음)
#
# 사용법:
#   zsh scripts/pack-release.sh
#   zsh /path/to/ahakeyconfig/scripts/pack-release.sh
#
# 선택 환경 변수: NOTARY_PROFILE, SIGNING_IDENTITY, SIGNING_IDENTITY_HINT, OUTPUT_DIR, DMG_BASENAME

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_ROOT"

if [[ -f "$SCRIPT_DIR/build.local.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/build.local.env"
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-AhaKeyNotary}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGNING_IDENTITY_HINT="${SIGNING_IDENTITY_HINT:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$APP_ROOT/dist}"
if [[ -z "${DMG_BASENAME:-}" ]]; then
  DMG_BASENAME="AhaKey-Studio-macOS-prod-$(date +%Y%m%d%H%M%S)"
fi

echo "🚀 Building formal distribution DMG → $DMG_BASENAME.dmg"

if [[ -z "$SIGNING_IDENTITY" && -n "$SIGNING_IDENTITY_HINT" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | grep -F "$SIGNING_IDENTITY_HINT" | head -n 1 | sed -E 's/.*"(.+)"/\1/' || true)"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -n 1 | sed -E 's/.*"(.+)"/\1/' || true)"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "❌ Missing Developer ID Application certificate."
  echo "   Install the certificate in your login keychain, then retry."
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "❌ Notary profile '$NOTARY_PROFILE' is not available."
  echo "   Create it first with:"
  echo "   xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>"
  exit 1
fi

RELEASE_DISTRIBUTION=1 \
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
SIGNING_IDENTITY_HINT="$SIGNING_IDENTITY_HINT" \
NOTARY_PROFILE="$NOTARY_PROFILE" \
OUTPUT_DIR="$OUTPUT_DIR" \
DMG_BASENAME="$DMG_BASENAME" \
zsh "$SCRIPT_DIR/package_dmg.sh"

echo "✅ Formal distribution package complete."

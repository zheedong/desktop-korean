#!/usr/bin/env bash
# AhaKeyConfig를 ad-hoc 서명된 "AhaKey Studio.app"으로 조립한다.
# 로컬과 CI에서 공용으로 사용하며, 산출물은 ahakeyconfig-mac/dist/에 생성된다.
#
#   APP_VERSION=1.2.3 APP_BUILD=42 scripts/package_app.sh
#
# 버전 번호는 환경 변수로 덮어쓸 수 있고, 기본값은 version=0.0.0, build=git 커밋 수다.
set -euo pipefail

cd "$(dirname "$0")/.."          # -> ahakeyconfig-mac

CONFIG="release"
APP_NAME="AhaKey Studio"
EXEC="AhaKeyConfig"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG} --product ${EXEC}"
swift build -c "${CONFIG}" --product "${EXEC}"
BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}/${EXEC}" "${APP}/Contents/MacOS/${EXEC}"

VERSION="${APP_VERSION:-0.0.0}"
BUILD="${APP_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# EmbeddedInfo.plist에는 TCC 권한 키만 들어 있다(바이너리의 __info_plist 섹션에 이미 포함됨).
# bundle의 Contents/Info.plist에는 CFBundleExecutable 등의 키도 필요하므로 여기서 보완한다.
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>lab.jawa.ahakeyconfig</string>
	<key>CFBundleExecutable</key><string>${EXEC}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSBluetoothAlwaysUsageDescription</key><string>AhaKey 설정에서 AhaKey 키보드에 연결하려면 Bluetooth가 필요합니다.</string>
	<key>NSMicrophoneUsageDescription</key><string>AhaKey Studio에서 Apple 기본 음성 인식을 사용하려면 마이크 접근 권한이 필요합니다.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>AhaKey Studio에서 음성 키를 Apple 기본 음성 인식으로 변환하려면 음성 인식 권한이 필요합니다.</string>
</dict>
</plist>
PLIST

# 기본 리소스(OLED 애니메이션 등). 존재할 때만 복사한다.
if [ -d "Resources" ]; then
	cp -R "Resources/." "${APP}/Contents/Resources/" 2>/dev/null || true
fi

# ad-hoc 서명. 로컬/CI 검사 시 Gatekeeper가 산출물을 서명된 것으로 인식하게 한다(공증은 아님).
codesign --force --deep --sign - "${APP}" 2>/dev/null || echo "warn: codesign skipped (no codesign available)"

echo "==> done: ${APP}  (version ${VERSION}, build ${BUILD})"

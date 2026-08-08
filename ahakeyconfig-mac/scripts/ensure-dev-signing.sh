#!/bin/zsh
# 로컬 개발 전용: login keychain에 안정적인 자체 서명 코드 서명 인증서가 있도록 보장합니다.
#
# 용도: Debug 빌드의 매 codesign이 동일한 CN으로 서명하도록 하여,
# 코드 수정으로 cdhash가 바뀌어도 macOS TCC가 인증서 CN 기준으로
# "입력 모니터링 / 손쉬운 사용 / 마이크 / 음성 받아쓰기" 등의 권한을 인식해, 매번 다시 체크할 필요가 없습니다.
#
# stdout: 인증서 SHA-1 지문(codesign --sign에 사용)
# stderr: 모든 진행 정보
#
# 왜 CN이 아니라 SHA-1을 출력하나?
#   자체 서명 인증서는 시스템 trust가 없어 `codesign --sign "<CN>"`은 "no identity found" 오류가 납니다.
#   반면 `codesign --sign "<SHA-1>"`은 trust 검사를 우회하고 개인 키로 바로 서명합니다.
#   서명된 결과의 Authority 필드는 여전히 CN "AhaKey Local Dev"이고 TCC는 이 필드로 인식하므로,
#   CN은 안정적이어야 합니다(빌드마다 이름을 바꾸면 안 됨).
#
# 참고:
# - 정식 릴리스 과정에는 영향이 없습니다. scripts/build.sh는 이 스크립트를 호출하지 않습니다.
# - 인증서는 login keychain에만 있으며, 시스템에 신뢰를 추가하지도, 어디에도 업로드하지도 않습니다.
# - 최초 생성 시 macOS가 "codesign의 키 접근 허용" 안내를 한 번 표시할 수 있습니다.
#   "항상 허용"을 누르면 이후에는 다시 묻지 않습니다.

set -euo pipefail

CERT_CN="${AHAKEY_DEV_CERT_CN:-AhaKey Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# CN 정확 일치로 SHA-1 조회
find_valid_sha1() {
  local cn="$1"
  security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null \
    | awk -v cn="\"$cn\"" '$0 ~ cn {print $2; exit}'
}

# 정규식 매칭으로 첫 번째 유효한 identity 조회("Apple Development: ..."를 찾는 데 사용)
find_valid_by_pattern() {
  local pat="$1"
  security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null \
    | awk -v pat="$pat" '$0 ~ pat {print $2; exit}'
}

# 우선순위 1: Apple Development 인증서(Xcode에서 Apple ID 로그인으로 생성됨)
#   TCC가 안정적으로 매칭되는 가장 확실한 경로입니다 — Apple root chain으로 서명된 앱은
#   TCC가 designated requirement 기준으로 엄격하게 평가하므로, cdhash가 바뀌어도 권한을 잃지 않습니다.
apple_dev="$(find_valid_by_pattern 'Apple Development: ')"
if [[ -n "$apple_dev" ]]; then
  >&2 echo "🍎 [ensure-dev-signing] Apple Development 인증서 사용 $apple_dev"
  echo "$apple_dev"
  exit 0
fi

# 우선순위 2: 자체 서명 AhaKey Local Dev(이미 존재하고 신뢰된 경우)
valid="$(find_valid_sha1 "$CERT_CN")"
if [[ -n "$valid" ]]; then
  >&2 echo "🔏 [ensure-dev-signing] 자체 서명 인증서 사용 '$CERT_CN' $valid"
  >&2 echo "   팁: 이후 Xcode에서 Apple ID로 로그인해 'Apple Development' 인증서를 생성하면,"
  >&2 echo "   이 스크립트가 자동으로 그 인증서로 전환합니다(더 안정적이며, 별도 조치 불필요)."
  echo "$valid"
  exit 0
fi

TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# CN 정확 일치로 상태와 무관하게 identity 조회(untrusted 포함)
find_any_sha1() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v cn="\"$CERT_CN\"" '$0 ~ cn {print $2; exit}'
}

# 경우 A: 인증서가 keychain에 있지만 신뢰되지 않음 → 신뢰만 추가하면 되고, 재생성은 불필요
untrusted="$(find_any_sha1)"
if [[ -n "$untrusted" ]]; then
  >&2 echo "🔐 [ensure-dev-signing] '$CERT_CN'을(를) 찾았지만 codesign 신뢰로 표시되지 않아 trust를 추가합니다…"
  # add-trusted-cert에서 사용할 수 있도록 기존 인증서를 PEM으로 내보냅니다
  security find-certificate -c "$CERT_CN" -p "$KEYCHAIN" > "$TMPDIR_LOCAL/cert.pem"
else
  >&2 echo "🔐 [ensure-dev-signing] 로컬 자체 서명 코드 서명 인증서 '$CERT_CN'을(를) 처음 생성합니다…"

  if ! command -v openssl >/dev/null 2>&1; then
    >&2 echo "❌ openssl을 찾을 수 없어 인증서를 생성할 수 없습니다"
    exit 1
  fi

  # Apple code signing policy 요구 사항:
  #   keyUsage=digitalSignature
  #   extendedKeyUsage=codeSigning
  #   basicConstraints=CA:FALSE
  # 하나라도 빠지면 codesign이 "Invalid Key Usage for policy" 오류를 냅니다
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TMPDIR_LOCAL/key.pem" \
    -out "$TMPDIR_LOCAL/cert.pem" \
    -days 3650 \
    -subj "/CN=$CERT_CN" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" \
    >/dev/null 2>&1

  PFX_PASS="ahakey-dev-$(date +%s)"
  # OpenSSL 3.x는 기본적으로 최신 형식(AES-256-CBC/PBKDF2)으로 내보내지만,
  # macOS `security import`는 전통적인 PKCS#12(RC2/3DES)만 지원합니다.
  # `-legacy`로 전통 형식으로 강제 회귀합니다.
  # LibreSSL / OpenSSL 1.1.x는 -legacy를 인식하지 못하므로 fallback을 추가합니다.
  if ! openssl pkcs12 -export -legacy \
      -in "$TMPDIR_LOCAL/cert.pem" \
      -inkey "$TMPDIR_LOCAL/key.pem" \
      -out "$TMPDIR_LOCAL/bundle.p12" \
      -name "$CERT_CN" \
      -password "pass:$PFX_PASS" \
      >/dev/null 2>&1; then
    openssl pkcs12 -export \
      -in "$TMPDIR_LOCAL/cert.pem" \
      -inkey "$TMPDIR_LOCAL/key.pem" \
      -out "$TMPDIR_LOCAL/bundle.p12" \
      -name "$CERT_CN" \
      -password "pass:$PFX_PASS" \
      >/dev/null 2>&1
  fi

  security import "$TMPDIR_LOCAL/bundle.p12" \
    -k "$KEYCHAIN" \
    -P "$PFX_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

  # codesign이 암호 없이 개인 키를 사용하도록 자동 허용을 시도합니다. 실패해도 "첫 서명 때 안내가 한 번 뜨는" 것뿐이고,
  # 인증서 자체의 사용 가능성에는 영향이 없습니다.
  security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -s \
    "$KEYCHAIN" >/dev/null 2>&1 || {
    >&2 echo "   ⚠️  키체인 접근을 자동으로 허용하지 못했습니다. 첫 서명 시 암호 창이 한 번 뜰 수 있으며, '항상 허용'을 선택하면 됩니다."
  }
fi

# 사용자 수준 code signing trust 설정 — codesign은 policy 평가를 통과한 identity만 받아들입니다.
# 이 단계에서 macOS 대화 상자가 한 번 떠서 사용자에게 Touch ID / 로그인 암호 확인을 요청하며,
# 이후에는 영구적으로 적용됩니다(다음 빌드에서는 다시 뜨지 않음).
>&2 echo "🔑 [ensure-dev-signing] 인증서를 codesign 신뢰로 표시하는 중입니다;"
>&2 echo "   macOS 대화 상자가 한 번 뜨면 Touch ID / 로그인 암호로 확인해 주세요."
if ! security add-trusted-cert -r trustRoot -p codeSign \
      -k "$KEYCHAIN" \
      "$TMPDIR_LOCAL/cert.pem" 2>>/tmp/ahakey-ensure-dev-signing.log; then
  >&2 echo "❌ add-trusted-cert 실패(/tmp/ahakey-ensure-dev-signing.log 확인)"
  >&2 echo "   방금 대화 상자를 취소했다면, 이 스크립트를 다시 실행하면 됩니다."
  exit 1
fi

sha1="$(find_valid_sha1 "$CERT_CN")"
if [[ -z "$sha1" ]]; then
  >&2 echo "❌ 인증서가 신뢰된 후에도 codesign이 유효한 identity로 인식하지 못합니다"
  exit 1
fi

>&2 echo "✅ 인증서 '$CERT_CN' 준비 완료 (SHA-1 $sha1). 이후 모든 Debug 빌드가 이 인증서로 서명됩니다."
echo "$sha1"

#!/bin/zsh
# HalfShell.app 번들을 빌드한다. 결과물: build/HalfShell.app
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HalfShell.app
ICNS=build/AppIcon.icns

# Apple Silicon + Intel 유니버설 바이너리. 개발 기기 아키텍처로만 빌드하면
# 다른 쪽 Mac 에서는 실행 자체가 되지 않는다.
swift build -c release --arch arm64 --arch x86_64
BINARY=.build/apple/Products/Release/HalfShell
[[ -f "$BINARY" ]] || BINARY=.build/release/HalfShell

# --- 앱 아이콘 (스크립트가 더 최신일 때만 다시 생성) ---
if [[ ! -f "$ICNS" || scripts/make-icon.swift -nt "$ICNS" ]]; then
  echo "앱 아이콘 생성 중..."
  ICONWORK=$(mktemp -d)
  swift scripts/make-icon.swift "$ICONWORK"
  ICONSET="$ICONWORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
              "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
              "512:512x512" "1024:512x512@2x"; do
    px=${spec%%:*}
    name=${spec##*:}
    sips -z "$px" "$px" "$ICONWORK/icon-1024.png" --out "$ICONSET/icon_$name.png" >/dev/null
  done
  mkdir -p build
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONWORK"
fi

# --- 앱 번들 조립 ---
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp "$ICNS" "$APP/Contents/Resources/"

# 오픈소스 라이선스 고지. MIT 는 배포할 때 저작권 표시와 라이선스 문구를 함께
# 넣을 것을 조건으로 한다 — HalfShell 자신과, 실행 파일에 함께 들어가는 의존성
# (지금은 Sentry) 모두. 의존성 목록은 SwiftPM 이 받아 둔 checkouts 에서 그대로
# 모은다. 손으로 옮겨 적으면 의존성이 늘어날 때 빠뜨리기 쉽다.
LICENSES="$APP/Contents/Resources/Licenses.txt"
{
  echo "HalfShell includes the following open source software."
  echo "HalfShell 에는 다음 오픈소스 소프트웨어가 포함되어 있습니다."
  echo
  echo "------------------------------------------------------------"
  echo "HalfShell"
  echo "------------------------------------------------------------"
  cat LICENSE
  for lic in .build/checkouts/*/LICENSE*(N); do
    echo
    echo "------------------------------------------------------------"
    echo "$(basename "$(dirname "$lic")")"
    echo "------------------------------------------------------------"
    cat "$lic"
  done
} > "$LICENSES"

# 지역화 파일. .lproj 폴더째로 넣어야 macOS 가 시스템 언어에 맞춰 고른다.
# (진단 로그는 번역 대상이 아니다 — POSTMORTEM 의 사건 분석이 한글 로그 줄을
#  그대로 인용하므로, 옮기면 진단 대조표가 어긋난다.)
for lproj in Resources/*.lproj; do
  [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# 서명. 가능한 한 실제 인증서를 쓴다.
#
# ad-hoc 서명(`-`)은 팀 ID 가 없고 재빌드할 때마다 해시가 바뀌어서, macOS 가
# 매번 다른 앱으로 본다. 그러면 **손쉬운 사용 권한이 붙지 않는다.** 비상 탈출이
# 조용히 죽는 원인이 이것이었다. 정식 인증서로 서명하면 팀 ID 가 고정되어
# 권한이 재빌드 후에도 유지된다.
#
# 우선순위: Developer ID(배포용) → Apple Development(로컬) → ad-hoc(최후)
pick_identity() {
  local list id
  list=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for prefix in "Developer ID Application" "Apple Development"; do
    id=$(printf '%s\n' "$list" | grep -F "$prefix" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  printf '%s\n' "-"
}
IDENTITY=$(pick_identity)
if [[ "$IDENTITY" == "-" ]]; then
  echo "경고: 정식 인증서가 없어 ad-hoc 으로 서명합니다."
  echo "      재빌드할 때마다 손쉬운 사용 권한이 풀릴 수 있습니다."
else
  echo "서명: $IDENTITY"
fi
# Hardened Runtime 은 항상 켠다. 공증의 필수 조건이고, 개발 빌드에서도 켜 둬야
# 배포판과 같은 조건에서 시험하게 된다. SkyLight 는 Apple 이 서명한 시스템
# 프레임워크라 Hardened Runtime 에서도 불러올 수 있다.
#
# 보안 타임스탬프는 Developer ID 일 때만 붙인다. 공증의 필수 조건이지만 Apple
# 서버에 접속해야 해서, 개발 빌드까지 붙이면 오프라인에서 빌드가 안 된다.
SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  SIGN_FLAGS+=(--timestamp)
else
  SIGN_FLAGS+=(--timestamp=none)
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict "$APP"

echo "완료: $APP"
echo "설치: ./install.sh    (또는 Finder에서 응용 프로그램으로 드래그)"

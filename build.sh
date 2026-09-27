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
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"

echo "완료: $APP"
echo "설치: ./install.sh    (또는 Finder에서 응용 프로그램으로 드래그)"

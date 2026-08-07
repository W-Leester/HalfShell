#!/bin/zsh
# AutoClamshell.app 번들을 빌드한다. 결과물: build/AutoClamshell.app
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AutoClamshell.app
ICNS=build/AppIcon.icns

swift build -c release

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
cp .build/release/AutoClamshell "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp "$ICNS" "$APP/Contents/Resources/"

# 로컬 실행용 ad-hoc 서명 (SMAppService 로그인 등록에 필요)
codesign --force --sign - "$APP"

echo "완료: $APP"
echo "설치: ./install.sh    (또는 Finder에서 응용 프로그램으로 드래그)"

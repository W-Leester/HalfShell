#!/bin/zsh
# 배포용 DMG 인스톤러를 만든다. 결과물: dist/AutoClamshell-<버전>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AutoClamshell.app
[[ -d "$APP" ]] || ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/AutoClamshell-$VERSION.dmg"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/응용 프로그램"

cat > "$STAGE/먼저 읽어주세요.txt" <<'EOF'
AutoClamshell 설치 방법
========================

1. AutoClamshell.app 을 "응용 프로그램" 폴더로 드래그합니다.

2. 이 앱은 Apple 개발자 서명이 없어서 처음 실행할 때 macOS가 차단합니다.
   터미널에서 아래 한 줄을 실행하면 해제됩니다:

       xattr -cr /Applications/AutoClamshell.app

   (또는 앱을 우클릭 → "열기" → 대화상자에서 다시 "열기")

3. 실행하면 창이 뜨지 않고 메뉴바 오른쪽에 노트북 아이콘이 생깁니다.
   그 아이콘을 클릭해 "외장 연결 시 내장 디스플레이 자동 끄기"를 켜세요.

주의: Lunar / BetterDisplay 의 disconnect(BlackOut) 기능과 동시에 쓰면
      서로 충돌하므로 둘 중 하나만 사용하세요.
EOF

mkdir -p dist
rm -f "$DMG"
hdiutil create \
  -volname "AutoClamshell" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"

echo "완료: $DMG"
echo "다른 Mac으로 복사해서 열면 드래그 설치할 수 있습니다."

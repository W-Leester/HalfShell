#!/bin/zsh
# 배포용 DMG 인스톤러를 만든다. 결과물: dist/HalfShell-<버전>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HalfShell.app
[[ -d "$APP" ]] || ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/HalfShell-$VERSION.dmg"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/응용 프로그램"

cat > "$STAGE/먼저 읽어주세요.txt" <<'EOF'
HalfShell 설치 방법
========================

1. HalfShell.app 을 "응용 프로그램" 폴더로 드래그합니다.

2. 이 앱은 Apple 개발자 서명이 없어서 처음 실행할 때 macOS가 차단합니다.
   터미널에서 아래 한 줄을 실행하면 해제됩니다:

       xattr -cr /Applications/HalfShell.app

   (또는 앱을 우클릭 → "열기" → 대화상자에서 다시 "열기")

3. 실행하면 창이 뜨지 않고 메뉴바 오른쪽에 노트북 아이콘이 생깁니다.
   그 아이콘을 클릭해 "외장 연결 시 내장 디스플레이 자동 끄기"를 켜세요.


지원 환경
=========

- macOS 13 이상, 내장 디스플레이가 있는 Mac (MacBook 계열)
- Mac mini / Studio / Pro 는 내장 디스플레이가 없어 사용할 수 없습니다.
  앱은 실행되지만 메뉴에 그 사실을 표시하고 기능이 잠깁니다.
- Apple Silicon 에서 검증했습니다. Intel Mac 에서도 실행되지만 검증하지
  못했으며, 동작하지 않으면 메뉴에 그 사실이 표시됩니다.


주의사항
========

- Lunar / BetterDisplay 의 disconnect(BlackOut) 기능과 동시에 쓰면 서로
  충돌합니다. 둘 중 하나만 사용하세요.

- macOS 가 공개하지 않은 기능을 사용합니다. 큰 폭의 macOS 업데이트 후에는
  동작을 다시 확인해 주세요.

- "Command 5번 연타" 비상 탈출 기능만 손쉬운 사용 권한이 필요합니다.
  허용하지 않아도 자동 끄기와 자동 복구는 정상 동작합니다.


혹시 화면이 안 켜지면
=====================

외장 디스플레이를 다시 연결하면 즉시 돌아옵니다.
그래도 안 되면 터미널에서:

    pkill -x HalfShell
EOF

mkdir -p dist
rm -f "$DMG"
hdiutil create \
  -volname "HalfShell" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"

echo "완료: $DMG"
echo "다른 Mac으로 복사해서 열면 드래그 설치할 수 있습니다."

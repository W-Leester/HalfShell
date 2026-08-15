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

- macOS 가 공개하지 않은 기능을 사용합니다. 큰 폭의 macOS 업데이트 후에는
  동작을 다시 확인해 주세요.


Lunar / BetterDisplay 를 함께 쓰신다면
======================================

앱 전체가 충돌하는 것은 아닙니다. 지울 필요도 없습니다.
내장 디스플레이를 끄고 켜는 기능만 겹칩니다.

  겹침    Lunar 의 BlackOut / Auto BlackOut
          BetterDisplay 의 disconnect

  괜찮음  밝기 조절, DDC 제어, 색온도, 프리셋 등 나머지 전부

겹치는 기능을 양쪽 다 켜두면 두 앱이 서로 되돌리며 싸웁니다. 한쪽이
끄면 다른 쪽이 켜고, 그것을 다시 끄는 일이 반복됩니다. 화면이 계속
깜빡이고, 창 위치가 흐트러지고, 배터리가 빨리 닳습니다.

내장 디스플레이는 둘 중 한 앱에만 맡기세요.

  - Lunar 의 BlackOut 을 쓰시겠다면 → HalfShell 을 종료
  - HalfShell 을 쓰시겠다면 → Lunar 의 Auto BlackOut 을 끄기

나머지 기능은 그대로 함께 쓰셔도 됩니다.

설치 직후 꼭 해두세요 (비상 탈출)
=================================

만에 하나 화면이 안 켜지는 상황이 오면, 화면이 보이지 않으니 마우스도
터미널도 쓸 수 없습니다. 그때 손만으로 빠져나올 수 있는 방법을 미리
열어두는 설정입니다.

  시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → HalfShell 켜기

  ※ 이름이 똑같은 "시스템 설정 → 손쉬운 사용"은 다른 곳입니다.
     VoiceOver 같은 항목이 보이면 잘못 찾아온 것입니다.

허용하면 Command 키를 2초 안에 5번 연타하는 것만으로 내장 화면이 켜집니다.
허용하지 않아도 자동 끄기와 자동 복구는 정상 동작하지만, 비상 탈출은
쓸 수 없습니다.


혹시 화면이 안 켜지면
=====================

화면이 보이지 않아도 아래 방법으로 복구됩니다. 위에서부터 시도하세요.

1. Command 키를 2초 안에 5번 연타합니다.
   가장 빠릅니다. 위의 손쉬운 사용 권한을 허용해 둔 경우에만 됩니다.

2. 외장 디스플레이 케이블을 다시 연결합니다.
   연결되는 즉시 화면이 돌아옵니다. 권한 설정과 무관하게 항상 됩니다.

3. 그래도 안 되면 전원 버튼을 길게 눌러 강제 재시작합니다.
   재시작하면 디스플레이 설정이 초기화되어 화면이 돌아옵니다.
   저장하지 않은 작업은 사라지므로 마지막 수단입니다.
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

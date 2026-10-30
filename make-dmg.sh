#!/bin/zsh
# 배포용 DMG 를 만든다.
#
#   ./make-dmg.sh                  배포용 — Developer ID 서명 + 공증 + 스테이플
#   ./make-dmg.sh --no-notarize    시험용 — 공증 없이 DMG 만 (다른 Mac 에서는 Gatekeeper 가 막는다)
#
# 결과물 (배포용):
#   dist/HalfShell-<버전>.dmg   버전별 이름 — GitHub Release 와 웹사이트의 버전 목록이 가리킨다
#   dist/HalfShell.dmg          고정 이름   — 웹사이트 다운로드 버튼이 releases/latest/download/ 로 가리킨다
# 두 파일은 내용이 같다. 릴리스마다 둘 다 첨부한다(DISTRIBUTION.md).
#
# 공증 자격증명은 키체인에 한 번 등록해 둔다. 저장소에는 넣지 않는다.
#   xcrun notarytool store-credentials "halfshell-notary" \
#     --apple-id <Apple ID> --team-id FS39W6C7X9          (앱 암호를 묻는다)
# 다른 이름으로 등록했다면 NOTARY_PROFILE=<이름> ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0
PROFILE="${NOTARY_PROFILE:-halfshell-notary}"

fail() { echo "오류: $*" >&2; exit 1; }

# ── 0. 사전 확인 — 오래 걸리는 빌드·공증 전에 막을 것은 먼저 막는다 ──
if (( NOTARIZE )); then
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "Developer ID Application 인증서가 키체인에 없습니다. (시험용은 --no-notarize)"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "공증 자격증명 '$PROFILE' 이 키체인에 없습니다. 이 파일 맨 위의 store-credentials 를 먼저 실행하세요."
fi

# ── 1. 빌드 — 배포물은 항상 새로 빌드한다. 남아 있던 옛 빌드를 그대로 싸면 안 된다 ──
./build.sh
APP=build/HalfShell.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
echo "버전 $VERSION · 서명 $AUTHORITY"
if (( NOTARIZE )); then
  [[ "$AUTHORITY" == "Developer ID Application"* ]] || fail "앱이 Developer ID 로 서명되지 않았습니다: $AUTHORITY"
fi

# 공증 제출 후 결과 확인. --wait 는 거절돼도 성공으로 끝날 수 있어 상태를 직접 읽는다.
notarize() {
  local file="$1" out result id
  echo "공증 제출: $(basename "$file") — 보통 몇 분 걸립니다"
  out=$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json)
  result=$(printf '%s' "$out" | plutil -extract status raw -o - - 2>/dev/null || echo "?")
  id=$(printf '%s' "$out" | plutil -extract id raw -o - - 2>/dev/null || echo "?")
  if [[ "$result" != "Accepted" ]]; then
    echo "$out" >&2
    fail "공증 거절($result). 이유 보기: xcrun notarytool log $id --keychain-profile $PROFILE"
  fi
  echo "공증 통과 ($id)"
}

# ── 2. 앱 자체를 공증하고 스테이플 ──
# DMG 만 공증해도 되지만, 그러면 사용자가 DMG 에서 꺼낸 앱을 처음 열 때 Apple 서버에
# 물어봐야 한다. 앱에도 공증 결과를 붙여 두면 오프라인에서도 바로 열린다.
if (( NOTARIZE )); then
  ZIP=$(mktemp -d)/HalfShell.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# ── 3. DMG 조립 ──
DMG="dist/HalfShell-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
# 바로가기 이름은 영어로 둔다. Finder 는 바로가기 이름을 번역하지 않아서, 한국어로
# 두면 영어 사용자에게 그대로 한국어로 보인다. "Applications" 는 어느 쪽에서나 통한다.
ln -s /Applications "$STAGE/Applications"
cp Resources/DMG-ReadMe.txt "$STAGE/Read Me.txt"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "HalfShell" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ── 4. DMG 서명·공증·스테이플 ──
if (( NOTARIZE )); then
  codesign --force --timestamp --sign "$AUTHORITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  # ── 5. 받는 사람의 Mac 이 할 검사를 미리 해 본다 ──
  xcrun stapler validate "$DMG" >/dev/null
  spctl -a -t open --context context:primary-signature "$DMG" \
    || fail "Gatekeeper 가 DMG 를 거부합니다"
  spctl -a -t exec "$APP" || fail "Gatekeeper 가 앱을 거부합니다"
  echo "Gatekeeper 검사 통과 (DMG, 앱)"
fi

cp "$DMG" dist/HalfShell.dmg

echo
echo "완료:"
echo "  $DMG"
echo "  dist/HalfShell.dmg"
echo "  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)   (Homebrew cask 에 쓴다)"
if (( ! NOTARIZE )); then
  echo
  echo "※ 시험용입니다 — 공증하지 않아 다른 Mac 에서는 Gatekeeper 가 막습니다."
fi

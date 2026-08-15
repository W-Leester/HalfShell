#!/bin/zsh
# 빌드한 앱을 /Applications 로 설치한다 (실행 중이면 먼저 종료).
set -euo pipefail
cd "$(dirname "$0")"

SRC=build/HalfShell.app
DEST=/Applications/HalfShell.app

if [[ ! -d "$SRC" ]]; then
  echo "먼저 ./build.sh 를 실행하세요." >&2
  exit 1
fi

if pgrep -x HalfShell >/dev/null; then
  echo "실행 중인 HalfShell 종료 중... (내장 디스플레이가 복구됩니다)"
  osascript -e 'quit app "HalfShell"' 2>/dev/null || pkill -x HalfShell || true
  # 종료 시 디스플레이 복구가 끝날 때까지 잠시 대기
  for _ in {1..20}; do
    pgrep -x HalfShell >/dev/null || break
    sleep 0.25
  done
fi

rm -rf "$DEST"
cp -R "$SRC" "$DEST"
xattr -cr "$DEST"

echo "설치 완료: $DEST"
open "$DEST"
echo "메뉴바 오른쪽에 노트북 아이콘이 나타납니다."

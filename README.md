# AutoClamshell

뚜껑을 **연 채로** 내장 디스플레이만 끄고 외장 디스플레이를 단독 사용하게 해주는 macOS 메뉴바 앱.
클램쉘 모드의 화면 구성은 그대로 가져오면서, 뚜껑을 닫아서 생기는 발열 문제를 피한다.

## 기능

- **자동 모드**: 켜두면 외장 디스플레이가 감지될 때 내장 디스플레이를 자동으로 끈다.
- 외장 디스플레이가 모두 분리되면 **자동 모드와 무관하게 내장을 즉시 복구**한다 (화면이 하나도 없는 상태 방지).
- 메뉴바에서 수동으로 끄기/켜기 가능. 수동으로 켜면 자동 모드도 함께 꺼진다.
- 앱을 종료하면 내장 디스플레이가 복구된다. 강제 종료(크래시 포함)되어도 OS가 자동으로 되돌린다(아래 참고).
- 로그인 시 자동 실행 옵션.

### 복구 규칙

우선순위가 높은 것부터 적용된다.

1. **외장이 하나도 없으면 무조건 내장을 켠다.** 다른 모든 규칙을 무시한다.
   화면이 하나도 없어서 조작 자체가 불가능해지는 상황을 막는 최후의 방어선.
2. 자동 모드가 꺼져 있으면, 이번 세션에서 사용자가 직접 끈 게 아닌 한 내장을 켠다.
   이전 인스턴스가 크래시했거나 다른 앱(Lunar 등)이 꺼둔 상태를 자가 치유한다.
3. 자동 모드 + 외장 존재 → 내장을 끈다.

감시 경로를 여러 겹으로 둔다. `CGDisplayRegisterReconfigurationCallback`(가장 빠름),
AppKit 화면 변경 알림, 메인 큐 워치독, 그리고 **`SafetyNet`**.

`SafetyNet` 이 규칙 1 전용 최후 방어선이다. 화면이 0개가 되면 이 앱은 창도 입력도
없는 완전한 백그라운드 프로세스가 되어 **App Nap 이 메인 런루프 타이머를 수십 초씩
지연**시킬 수 있다. 그래서 `SafetyNet` 은 전용 큐의 `DispatchSourceTimer` 를 쓰고
판단과 복구를 그 큐에서 끝낸다(MainActor 를 거치지 않는다). App Nap 자체도
`ProcessInfo.beginActivity` 로 막는다. 평상시 1초 주기로 돌다가, 재구성이 감지되면
6초 동안 0.1초 주기로 좁힌다.

### 로그

`~/Library/Logs/AutoClamshell.log` 에 기록한다. 메뉴바의 **로그 열기**로도 열 수 있다.
화면이 하나도 없는 순간에 무슨 일이 있었는지는 사후에 로그로만 확인할 수 있어서,
디스플레이 재구성 이벤트와 복구 시도를 모두 남긴다.

## 설치

DMG를 받았다면 열어서 `AutoClamshell.app`을 **응용 프로그램** 폴더로 드래그한 뒤,
터미널에서 격리 속성을 한 번 풀어준다 (아래 [Gatekeeper](#gatekeeper) 참고):

```sh
xattr -cr /Applications/AutoClamshell.app
```

실행해도 창은 뜨지 않는다. 메뉴바 오른쪽에 노트북 아이콘이 생기고, 거기서
"외장 연결 시 내장 디스플레이 자동 끄기"를 켜면 된다.

## 빌드

Xcode는 필요 없다. Command Line Tools의 Swift 툴체인만 있으면 빌드된다.

```sh
./build.sh      # build/AutoClamshell.app 생성 (아이콘 포함)
./install.sh    # 빌드한 앱을 /Applications 로 설치하고 실행
./make-dmg.sh   # 배포용 DMG 생성
```

요구사항: Apple Silicon, macOS 13+ (개발은 macOS 26 / M5에서 검증).

`install.sh`는 실행 중인 인스턴스를 먼저 종료한다. 이때 내장 디스플레이가 잠시
복구되었다가, 새로 실행된 앱이 자동 모드 설정에 따라 다시 끈다.

### 배포용 DMG

`./make-dmg.sh`는 `dist/AutoClamshell-<버전>.dmg`를 만든다. 버전은
`Resources/Info.plist`의 `CFBundleShortVersionString`에서 읽으므로, 버전을 올리려면
그 값만 수정하면 된다. 앱이 빌드되어 있지 않으면 `build.sh`를 먼저 호출한다.

DMG를 열면 세 가지가 보인다:

| 항목 | 용도 |
| --- | --- |
| `AutoClamshell.app` | 드래그할 앱 |
| `응용 프로그램` | `/Applications` 심볼릭 링크 (드래그 대상) |
| `먼저 읽어주세요.txt` | 설치 방법과 Gatekeeper 해제 안내 |

USB, AirDrop, 클라우드 등 아무 방법으로나 옮겨서 열면 된다.

### Gatekeeper

이 앱은 Apple 개발자 인증서가 아닌 **ad-hoc 서명**을 쓴다. 그래서 다운로드하거나
AirDrop으로 받은 경우 격리(quarantine) 속성이 붙어 macOS가 실행을 차단한다.
위의 `xattr -cr` 한 줄로 풀거나, 앱을 우클릭 → "열기" → 대화상자에서 다시 "열기"를
선택하면 된다. 한 번만 하면 이후로는 그냥 실행된다.

경고 자체를 없애려면 Apple Developer Program($99/년)의 Developer ID 인증서로 서명하고
`xcrun notarytool`로 공증해야 한다. 참고로 공증한 앱은 멤버십이 만료되어도 계속
동작한다(서명 시점의 타임스탬프로 검증하므로). 본인 Mac 몇 대에서만 쓴다면 ad-hoc
서명으로 충분하며, ad-hoc 서명에는 인증서가 없으므로 만료 개념도 없다.

## 동작 원리

macOS에는 디스플레이를 활성 배열에서 제거하는 공개 API가 없다. 이 앱은 SkyLight
비공개 프레임워크의 디스플레이 구성 트랜잭션을 사용한다:

```
SLSBeginDisplayConfiguration(&config)
SLSConfigureDisplayEnabled(config, displayID, false)
SLSCompleteDisplayConfigurationWithOption(config, 0 /* forAppOnly */)
```

- 밝기 0이나 미러링 꼼수가 아니라 **논리적 disconnect**다. 내장 디스플레이가
  `CGGetActiveDisplayList`에서 사라지고, 창과 마우스가 그쪽으로 갈 수 없게 된다.
  BetterDisplay / Lunar의 disconnect 기능과 같은 계열의 방식.
- `forAppOnly`(옵션 0)로 커밋하므로 **이 프로세스가 종료되면 변경이 자동으로 되돌아간다.**
  앱이 죽어도 내장 디스플레이가 꺼진 채 남지 않는 핵심 안전장치.
- 심볼은 `dlsym`으로 런타임에 찾는다. OS 업데이트로 비공개 심볼이 사라지면 기능이
  비활성화될 뿐 크래시하지 않는다.

### 꺼진 내장 디스플레이를 다시 찾는 법

논리적으로 끈 디스플레이는 `CGGetActiveDisplayList` 는 물론 **`CGGetOnlineDisplayList`
에서도 사라진다.** 그래서 목록 열거만으로는 복구할 ID를 알아낼 수 없다 — ID를 캐시해둔
인스턴스가 죽으면 되살릴 방법이 없어진다.

다행히 ID 자체는 살아 있어서 개별 조회에는 응답한다. 그래서 ID 공간(1...64)을 훑어
내장 디스플레이를 찾는다. 유효하지 않은 ID도 `CGDisplayIsBuiltin` 에 true 를 돌려주므로
그것만으로는 구분되지 않고, **vendor 번호(0xFFFFFFFF 가 아님)와 픽셀 크기(0 이 아님)**
까지 확인해야 실제 패널을 가려낼 수 있다.

덕분에 앱을 새로 실행하기만 해도 이전 인스턴스나 다른 앱이 꺼둔 내장 디스플레이를
찾아서 복구할 수 있다.

참고: Lunar 개발자가 시도했던 `SLSDisplayPowerControlClient`(powerd가 쓰는 진짜 클램쉘
트리거)는 Apple 전용 entitlement가 필요해서 서드파티 앱에서는 사용할 수 없다.
([리버스 엔지니어링 글](https://alinpanaitiu.com/blog/turn-off-macbook-display-clamshell/))

## 주의

- **Lunar / BetterDisplay와 동시 사용 금지**: 같은 디스플레이를 서로 제어하려고 하면
  충돌한다. 이 앱을 쓸 때는 해당 앱의 disconnect/BlackOut 기능을 꺼둘 것.
- 비공개 API이므로 macOS 메이저 업데이트 후에는 동작 확인이 필요하다.

## 프로젝트 구조

```
Sources/AutoClamshell/
  SkyLight.swift            # 비공개 API 브리지 (dlsym)
  DisplayController.swift   # 토폴로지 감시 + 자동 끄기/복구 상태 머신
  AutoClamshellApp.swift    # MenuBarExtra UI + 종료 시 복구
Resources/Info.plist        # LSUIElement (메뉴바 전용 앱), 버전 정보
scripts/make-icon.swift     # 앱 아이콘(.icns) 생성기
build.sh                    # .app 번들 빌드 + 아이콘 + ad-hoc 서명
install.sh                  # /Applications 설치
make-dmg.sh                 # 배포용 DMG 생성

build/                      # 빌드 산출물 (.app, .icns) — git 제외
dist/                       # 배포용 DMG — git 제외
```

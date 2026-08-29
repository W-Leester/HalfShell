import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

/// CoreGraphics 디스플레이 재구성 콜백. C 함수 포인터라 컨텍스트를 캡처할 수 없어
/// 싱글턴으로 넘긴다. 이 콜백 안에서 디스플레이 구성을 다시 바꾸면 재진입 교착이
/// 날 수 있으므로 메인 큐로 넘겨서 처리한다.
private func displayReconfigured(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    let isBegin = flags.contains(.beginConfigurationFlag)
    Log.write("[CG콜백] display=\(display) flags=\(flags.rawValue) begin=\(isBegin)")
    // 메인 런루프를 거치지 않는 안전망부터 깨운다. 화면이 사라지는 순간에는
    // 메인 큐가 지연될 수 있으므로 이쪽이 먼저 반응해야 한다.
    SafetyNet.shared.alert()
    let wasAdded = flags.contains(.addFlag)
    DispatchQueue.main.async {
        if wasAdded {
            DisplayController.shared.noteDisplayAdded(display)
        }
        DisplayController.shared.handleReconfiguration()
    }
}

/// 디스플레이 토폴로지를 감시하면서 내장 디스플레이를 끄고 켜는 상태 머신.
///
/// 규칙(우선순위 순):
///  1. 외장이 하나도 없으면 무조건 내장을 켠다. 다른 모든 규칙보다 우선한다.
///  2. 자동 모드가 꺼져 있으면, 이번 세션에서 사용자가 직접 끈 게 아닌 한 내장을 켠다.
///     — 이전 인스턴스 크래시나 다른 앱(Lunar 등)이 꺼둔 상태를 자가 치유한다.
///  3. 자동 모드 + 외장 존재 → 내장을 끈다.
///
/// 규칙 1은 화면이 하나도 없어 조작이 불가능해지는 것을 막는 안전 규칙이라
/// 이 클래스와 별개로 ``SafetyNet`` 이 메인 런루프 밖에서 한 번 더 보장한다.
@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    @Published var autoMode: Bool {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: Self.autoModeKey)
            if autoMode != oldValue {
                manuallyDisabled = false
                if autoMode { autoDisableArmed = true }
                Log.write("[설정] 자동 모드 \(autoMode ? "켜짐" : "꺼짐")")
            }
            evaluate()
        }
    }
    @Published private(set) var builtinOff = false
    @Published private(set) var externalConnected = false
    /// 이 Mac 에 내장 디스플레이가 있는지. Mac mini·Studio·Pro 에서는 false 이고,
    /// 그 경우 이 앱은 할 수 있는 일이 없으므로 UI 를 모두 잠근다.
    @Published private(set) var hasBuiltinDisplay = false
    @Published private(set) var lastError: String?
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// 손쉬운 사용 권한 상태. 시스템 설정에서 바뀌므로 워치독이 주기적으로 갱신한다.
    @Published private(set) var accessibilityTrusted = false

    var skyLightAvailable: Bool { SkyLight.shared != nil }

    /// 이 Mac 에서 앱이 제 역할을 할 수 있는지. 둘 중 하나라도 없으면 UI 를 잠근다.
    var isUsable: Bool { skyLightAvailable && hasBuiltinDisplay }

    private static let autoModeKey = "autoMode"
    private static let emergencyPromptedKey = "emergencyPermissionPrompted"
    /// 재구성 콜백이 실제 감지를 담당하므로 이 폴링은 예비 수단이다. 넉넉하게 둔다.
    private static let watchdogInterval: TimeInterval = 5
    /// 깨어난 뒤 이 시간 안에 들어온 디스플레이 추가는 "복원"으로 보고 무시한다.
    private static let wakeSettleWindow: TimeInterval = 5
    /// 깨어난 직후 내장 복구 재시도 횟수·간격. 커밋이 1001 로 밀리는 구간을 넘긴다.
    private static let wakeRestoreAttempts = 12
    private static let wakeRestoreInterval: TimeInterval = 0.5

    private var emergencyUnlock: EmergencyUnlock?

    /// 자동 모드가 꺼진 상태에서 사용자가 직접 끈 경우에만 true.
    /// 규칙 2가 곧바로 되돌리는 것을 막는다.
    private var manuallyDisabled = false
    /// 자동 끄기 무장 상태. 깨어난 직후에는 해제된다 — ``handleWake()`` 참고.
    private var autoDisableArmed = true

    /// 직전에 관찰한 뚜껑 상태. 워치독이 2초마다 도므로 바뀔 때만 로그를 남긴다.
    private var lidClosedLast = false

    /// 잠들기 전환 중인가. `willSleep` 에서 서고 `didWake` 에서 내려간다.
    ///
    /// 이 깃발이 없어서 사건 6이 났다. 잠들기 직전 선복구가 내장을 켜자 규칙 3이
    /// "외장 있고 내장 켜짐 → 끈다"며 잠드는 WindowServer 에 끄기 커밋을 냈고,
    /// 그 커밋이 **메인 스레드를 17분** 붙잡았다(다음 유지보수 깨어남까지).
    /// 잠들기 전환 중의 디스플레이 목록은 낡은 값일 수 있고, 그 순간 내린 어떤
    /// 판단도 커밋이 잠든 WindowServer 에 붙잡힐 수 있다. 판단 자체를 쉰다.
    ///
    /// 시각으로 기록하는 이유: 잠들기가 **취소**되면 `didWake` 가 오지 않을 수
    /// 있다. 불리언이면 깃발이 영영 서 있어 규칙 전체가 죽는다. 판단 중지는
    /// 어차피 전환의 몇 초를 덮으면 충분하므로 60초가 지나면 스스로 풀린다
    /// (진짜 잠들었다면 그 60초 동안 코드가 돌지 않으니 아무 차이가 없다).
    private var sleepBeganAt: Date?
    private static let sleepHoldDuration: TimeInterval = 60
    private var lastWakeAt = Date.distantPast
    private var pendingEvaluation: DispatchWorkItem?
    private var watchdog: Timer?
    /// 내장 디스플레이 ID. 꺼진 뒤에는 조회되지 않으므로 ``BuiltinDisplay`` 가 기억한다.
    private var builtinDisplayID: CGDirectDisplayID? { BuiltinDisplay.resolve() }

    private init() {
        autoMode = UserDefaults.standard.bool(forKey: Self.autoModeKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // 이 알림은 Dock 이 숨거나 전체화면 전환만 해도 온다 — 오늘 하루
            // 153회 중 실제 디스플레이 변화는 36회뿐이었다. 판단 계기로는 쓰되
            // 기록하지는 않는다. 실제 변화는 안전망이 남긴다.
            MainActor.assumeIsolated { self?.handleReconfiguration() }
        }

        // 잠들기 전에 내장을 되돌려 놓는다. 꺼진 채로 잠들면 깨어났을 때
        // 화면이 하나도 없는 상태에서 시작하게 되고, 그 상태에서는 사용자가
        // 메뉴를 볼 수도 없다. 자는 동안 켜져 있어도 손해가 없다.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
                self?.refreshAccessibilityStatus()
            }
        }
        // 여유를 크게 줘서 커널이 다른 깨우기와 묶을 수 있게 한다(전력 절약).
        watchdog?.tolerance = Self.watchdogInterval / 2

        emergencyUnlock = EmergencyUnlock { [weak self] in
            MainActor.assumeIsolated { self?.emergencyRestore() }
        }
        // 권한 요청은 최초 1회만 띄운다. 매 실행마다 뜨면 성가시기만 하다.
        let askedBefore = UserDefaults.standard.bool(forKey: Self.emergencyPromptedKey)
        applyEmergencyUnlock(requestingPermission: !askedBefore)
        UserDefaults.standard.set(true, forKey: Self.emergencyPromptedKey)

        Log.write("[시작] 자동 모드=\(autoMode) 내장 ID=\(builtinDisplayID.map(String.init) ?? "못 찾음") "
            + "SkyLight=\(skyLightAvailable)")
        evaluate()
    }

    // MARK: - 사용자 조작

    func manualDisable() {
        guard externalConnected else { return }
        manuallyDisabled = !autoMode
        autoDisableArmed = true   // 사용자가 직접 지시했으므로 보류를 푼다
        Log.write("[조작] 수동 끄기")
        disableBuiltin()
    }

    /// 수동/비상 켜기.
    ///
    /// **상태 판단에 기대지 않고 직접 켠다.** 이 경로는 화면이 보이지 않는 상황의
    /// 마지막 수단이므로, `evaluate()` 의 판단(활성 목록이 비면 잠자기로 보고 손을
    /// 떼는 등)이 어떤 이유로든 막히면 탈출까지 함께 막혀 버린다.
    /// 자동 모드도 함께 끈다. 켜기만 하면 규칙 3이 곧바로 다시 꺼버리기 때문이다.
    ///
    /// **켜는 것이 먼저다.** 반대 순서(`autoMode = false` 먼저)로 두면 didSet 의
    /// `evaluate()` 가 그 자리에서 규칙 2로 먼저 켜 버리고, 이 함수의 켜기는 이미
    /// 켜진 디스플레이에 대한 중복 커밋이 되어 실패한다(실측 13/13회, 코드 1001).
    /// 실패 자체는 무해했지만 메뉴에 가짜 오류가 뜨고 로그가 거짓을 말했다.
    /// 켜고 나서 자동 모드를 끄면 evaluate() 는 켜진 상태를 보므로 규칙 2 조건이
    /// 성립하지 않는다 — 커밋 직후 CG 목록이 갱신되어 있음은 실측으로 확인했다.
    func manualEnable() {
        manuallyDisabled = false
        Log.write("[조작] 수동 켜기")
        enableBuiltin(force: true)
        autoMode = false
    }

    /// Command 연타로 발동하는 비상 복구.
    ///
    /// 자동 모드까지 끄는 것이 핵심이다. 켜기만 하면 규칙 3이 곧바로 다시 꺼버려서
    /// 사용자는 "눌러도 안 된다"고 느끼게 된다.
    func emergencyRestore() {
        manualEnable()
    }

    /// 손쉬운 사용 권한을 요청한다. macOS 가 띄우는 대화상자에 "시스템 설정 열기"
    /// 버튼이 들어 있어, 설정 앱 식별자가 버전마다 달라지는 문제를 겪지 않는다.
    func requestAccessibilityPermission() {
        emergencyUnlock?.requestPermission()
    }

    /// 화면 복구 단축키는 **끌 수 없다.** 화면을 잃었을 때 손만으로 빠져나올 수 있는
    /// 유일한 수단이라, 사용자가 실수로 꺼둘 여지를 두지 않는다.
    private func applyEmergencyUnlock(requestingPermission: Bool) {
        guard let emergencyUnlock else { return }
        if requestingPermission, !emergencyUnlock.isTrusted {
            emergencyUnlock.requestPermission()
        }
        emergencyUnlock.start()
        refreshAccessibilityStatus()
    }

    private func refreshAccessibilityStatus() {
        guard let emergencyUnlock else { return }
        let trusted = emergencyUnlock.isTrusted
        if accessibilityTrusted != trusted { accessibilityTrusted = trusted }
        // 권한을 나중에 허용했다면 그때 모니터를 붙인다.
        if trusted, !emergencyUnlock.isRunning {
            emergencyUnlock.start()
        }
    }

    /// 종료 직전 복구. forAppOnly 커밋이 이중 안전망이지만 명시적으로도 되돌린다.
    func restoreForQuit() {
        watchdog?.invalidate()
        Log.write("[종료] 내장 디스플레이 복구")
        enableBuiltin()
    }

    // MARK: - 감시

    /// 잠들기 직전: 내장을 되돌려 놓는다.
    /// 잠들기 직전 시도.
    ///
    /// **메인 스레드를 막지 않는다.** 이 시점의 커밋은 실패하는 것이 정상이고
    /// (실측 2/2 실패, 오류 1001·1014), 실패할 때 **약 10초를 블로킹한다.**
    /// 그대로 두면 그만큼 잠자기 진입이 늦어진다.
    ///
    /// 그래서 최선 노력으로만 던져두고, 실제 보장은 깨어난 뒤
    /// ``restoreBuiltinPersistently(attemptsLeft:)`` 가 맡는다(실측으로 27ms 만에 복구).
    private func prepareForSleep() {
        sleepBeganAt = Date()
        Log.write("[시스템] 잠들기 — 내장 선복구 시도(실패해도 깨어날 때 복구한다)")
        guard let skyLight = SkyLight.shared, let id = builtinDisplayID else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try skyLight.setDisplay(id, enabled: true, scope: .session)
                Log.write("[시스템] 잠들기 선복구 성공")
            } catch {
                Log.write("[시스템] 잠들기 선복구 실패: \(error.localizedDescription)")
            }
        }
    }

    /// 깨어난 직후.
    ///
    /// **깨어난 뒤에 관찰된 외장만 보고 내장을 끄지 않는다.** 잠에서 깨어날 때
    /// macOS 가 이전 배치를 복원하면서, 실제로는 연결되어 있지 않은 디스플레이가
    /// 활성 목록에 나타나는 것을 실측으로 확인했다(사건 3 — 독을 뽑고 밖에서
    /// 뚜껑을 열었는데 `실제=[33, 34]` 로 보였고 화면은 검은 채였다).
    /// 그것을 실제 화면으로 착각하면 "화면이 있으니 내장은 꺼둬도 된다"고 판단해
    /// 검은 화면에서 깨어나게 된다.
    ///
    /// 그래서 깨어난 직후에는 내장을 켜고, **새로운 디스플레이 연결이 실제로
    /// 일어날 때까지** 자동 끄기를 보류한다. 책상에서 독을 꽂은 채 깨운 경우에는
    /// 내장이 함께 켜진 상태로 남으므로, 케이블을 다시 꽂거나 메뉴에서 한 번
    /// 눌러주면 된다. 검은 화면으로 깨어나는 것보다는 낫다.
    private func handleWake() {
        sleepBeganAt = nil
        Log.write("[시스템] 깨어남 — 내장 복구 후 자동 끄기 보류")
        // 유령 판별 실험: 깨어나는 순간이 유령이 태어나는 순간이므로,
        // 이때의 두 장부(화면 목록 vs 물리 링크)를 반드시 대조해 남긴다.
        let cgExternals = DisplayInfo.activeDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
        Log.write("[진단] 깨어남 대조 — 목록외장=\(cgExternals.sorted()) "
            + "\(PhysicalLink.describe()) 뚜껑=\(LidState.isClosed ? "닫힘" : "열림")")
        autoDisableArmed = false
        lastWakeAt = Date()
        restoreBuiltinPersistently(attemptsLeft: Self.wakeRestoreAttempts)
        handleReconfiguration()
    }

    /// 실제로 켜질 때까지 짧게 재시도한다.
    ///
    /// 잠들기·깨어나기 직후에는 WindowServer 가 아직 디스플레이 구성을 정리하는
    /// 중이라 커밋이 밀려 **오류 1001 로 실패한다**(실측). 한 번 호출하고 마는
    /// 방식이면 그 실패가 그대로 검은 화면이 된다 — 자동 모드가 켜져 있으면
    /// 규칙 1(외장 0개)도 규칙 2(자동 모드 꺼짐)도 발동 조건이 아니라
    /// 아무도 다시 켜주지 않기 때문이다.
    private func restoreBuiltinPersistently(attemptsLeft: Int) {
        if let builtin = builtinDisplayID,
           DisplayInfo.realActiveDisplays().contains(builtin) {
            return  // 이미 켜져 있다
        }
        // 뚜껑이 닫혀 있으면 복구할 것이 없다 — 정상적인 클램쉘이다.
        // 이 검사가 없어서 클램쉘 중 잠깐 깨어날 때마다 재시도 12번을 전부
        // 뚜껑 관문에 부딪히고는 "복구 실패"라는 **거짓 경보**를 Sentry 로
        // 보냈다(실측 2회). 진짜 사고가 양치기 신고에 묻히는 것이 가장 큰 손해다.
        if LidState.isClosed {
            Log.write("[시스템] 깨어남 복구 중단 — 뚜껑 닫힘(클램쉘). 복구할 것이 없다")
            return
        }
        guard attemptsLeft > 0 else {
            Log.write("[시스템] 내장 복구 재시도를 모두 소진했다")
            // 화면이 검은 채로 남았다는 뜻이다. 사용자는 이 순간 신고할 방법이 없다.
            Telemetry.report("깨어난 뒤 내장 디스플레이 복구 실패", extra: [
                "activeDisplays": DisplayInfo.activeDisplays().sorted().description,
                "realDisplays": DisplayInfo.realActiveDisplays().sorted().description,
                "autoMode": autoMode,
            ])
            return
        }
        enableBuiltin()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeRestoreInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.restoreBuiltinPersistently(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// 디스플레이가 새로 붙었을 때 호출된다. 깨어난 직후의 무더기 재구성과
    /// 사용자가 실제로 케이블을 꽂은 것을 구분하기 위해 시간차를 둔다.
    func noteDisplayAdded(_ display: CGDirectDisplayID) {
        guard !autoDisableArmed else { return }
        guard Date().timeIntervalSince(lastWakeAt) > Self.wakeSettleWindow else { return }
        guard CGDisplayIsBuiltin(display) == 0 else { return }
        autoDisableArmed = true
        Log.write("[자동] 새 외장 연결(display=\(display)) → 자동 끄기 재무장")
        handleReconfiguration()
    }

    /// 재구성 알림은 한 번의 변경에도 여러 번 몰려온다. 긴급 복구는 즉시 처리하고,
    /// 나머지 판단만 짧게 디바운스한다.
    func handleReconfiguration() {
        evaluate()  // 규칙 1(화면 전멸 방지)은 지연 없이 즉시 적용해야 한다
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func evaluate() {
        // 잠들기 전환 중에는 판단하지 않는다(사건 6). 이 사이의 디스플레이 목록은
        // 몇 초 전 값일 수 있고, 여기서 발행한 커밋은 잠든 WindowServer 에
        // 붙잡혀 다음 깨어남까지 돌아오지 않는다. 수동/비상 켜기(force)는
        // 이 관문을 거치지 않으므로 탈출은 막히지 않는다.
        if let began = sleepBeganAt {
            guard Date().timeIntervalSince(began) >= Self.sleepHoldDuration else { return }
            sleepBeganAt = nil  // didWake 없이 잠들기가 취소된 경우 — 스스로 푼다
        }

        // 활성 목록이 완전히 비어 있으면 잠자기 중이다. 이때 손대면 잠든 맥을 상대로
        // 복구를 반복하게 된다(커밋이 10초씩 블로킹되므로 전력 손실이 크다).
        // 진짜 위험 상황에서는 macOS 가 가상 디스플레이를 만들어 목록이 비지 않는다.
        guard !DisplayInfo.activeDisplays().isEmpty else { return }

        // 가상 자리표시자는 화면으로 세지 않는다. 그것을 외장으로 오인하면
        // "외장이 있으니 내장은 꺼둬도 된다"고 판단해 복구를 놓친다.
        let active = Set(DisplayInfo.realActiveDisplays())
        let externals = active.filter { CGDisplayIsBuiltin($0) == 0 }
        // 워치독이 2초마다 도므로, 값이 실제로 바뀔 때만 발행해 UI 갱신을 아낀다.
        if externalConnected != !externals.isEmpty { externalConnected = !externals.isEmpty }

        guard let builtin = builtinDisplayID else {
            // 내장 디스플레이가 없는 Mac (mini·Studio·Pro). 할 수 있는 일이 없다.
            if hasBuiltinDisplay { hasBuiltinDisplay = false }
            if builtinOff { builtinOff = false }
            return
        }
        if !hasBuiltinDisplay { hasBuiltinDisplay = true }
        let isOff = !active.contains(builtin)
        if builtinOff != isOff { builtinOff = isOff }

        // 뚜껑이 닫혀 있으면 내장이 꺼져 있는 것이 **정상**이다. 그게 클램쉘이다.
        // 이 구분이 없어서 규칙 2가 뚜껑 닫기를 "남이 껐다"로 오인하고 매번
        // 되돌렸다(사건 5). 아래 규칙 1·2는 뚜껑이 열려 있을 때만 의미가 있다.
        let lidClosed = LidState.isClosed
        if lidClosed != lidClosedLast {
            lidClosedLast = lidClosed
            Log.write("[뚜껑] \(lidClosed ? "닫힘 — 내장이 꺼진 것은 정상이므로 손대지 않는다" : "열림")")
        }

        if externals.isEmpty {
            // 외장이 하나도 없는 상태를 지나갔다면, 다음에 붙는 것은 진짜 연결이다.
            if !autoDisableArmed {
                autoDisableArmed = true
                Log.write("[자동] 외장 0개 확인 → 자동 끄기 재무장")
            }
            // 규칙 1: 외장이 없으면 무조건 켠다.
            // 뚜껑이 닫혀 있고 외장도 없다면 곧 잠자기로 들어간다. 그때 켜려 들면
            // 잠자기를 방해하며 전력만 태운다(사건 2와 같은 모양).
            if isOff, !lidClosed {
                Log.write("[규칙1] 외장 0개 + 내장 꺼짐 → 복구")
                enableBuiltin()
            }
        } else if autoMode {
            // 규칙 3. 단, 깨어난 직후 관찰만으로는 끄지 않는다(handleWake 참고).
            if !isOff, autoDisableArmed { disableBuiltin() }
        } else if isOff, !manuallyDisabled, !lidClosed {
            // 규칙 2: 자동 모드가 꺼져 있는데 내장이 꺼져 있다 → 자가 치유
            Log.write("[규칙2] 자동 모드 꺼짐 + 내장 꺼짐 → 자가 치유")
            enableBuiltin()
        }
    }

    // MARK: - 끄기/켜기

    private func disableBuiltin() {
        guard let skyLight = SkyLight.shared, let id = builtinDisplayID else { return }
        do {
            // appOnly: 앱이 죽으면 OS 가 되돌려주길 기대하는 방향으로 커밋한다.
            try skyLight.setDisplay(id, enabled: false, scope: .appOnly)
            builtinOff = true
            lastError = nil
            Log.write("[동작] 내장(id=\(id)) 끔")
            // 끈 직후가 비상 탈출이 가장 필요한 순간이자, 실제로 연타가 먹지
            // 않는다는 보고가 나온 구간이다. 무슨 일이 벌어지는지 기록한다.
            emergencyUnlock?.beginDiagnosticWindow(seconds: 30)
        } catch {
            lastError = error.localizedDescription
            Log.write("[동작] 내장 끄기 실패: \(error.localizedDescription)")
        }
    }

    /// 내장 디스플레이를 켠다.
    ///
    /// - Parameter force: 사용자가 직접 지시한 경로인가. 뚜껑 검사를 건너뛴다.
    ///
    /// **뚜껑이 닫혀 있으면 켜지 않는다(사건 5).** 닫힌 패널을 논리적으로 켜 봐야
    /// 사용자에게 보이는 것은 없고, 창만 보이지 않는 화면으로 끌려가며 잠자기까지
    /// 방해한다. 사건 2의 배터리 방전이 정확히 그 모양이었다.
    ///
    /// 켜는 경로가 여섯 군데라 각자 검사하게 두면 언젠가 하나를 빠뜨린다.
    /// 그래서 관문을 하나로 모았다. 단, 사용자가 명시적으로 누른 경로(`manualEnable`,
    /// 화면 복구 단축키)만은 통과시킨다 — 상태 판단이 어떤 이유로든 어긋났을 때
    /// 탈출까지 함께 막히면 안 된다.
    private func enableBuiltin(force: Bool = false) {
        if !force, LidState.isClosed {
            Log.write("[뚜껑] 닫힌 상태 — 내장 켜기를 건너뛴다(클램쉘 유지)")
            return
        }
        guard let skyLight = SkyLight.shared, let id = builtinDisplayID else { return }
        do {
            // session: appOnly 로 켜면 이 프로세스가 끝날 때 도로 꺼진다.
            try skyLight.setDisplay(id, enabled: true, scope: .session)
            builtinOff = false
            lastError = nil
            Log.write("[동작] 내장(id=\(id)) 켬. active=\(DisplayInfo.activeDisplays().sorted())")
        } catch {
            // 다른 경로가 먼저 켰다면 이 트랜잭션은 밀려서 실패한다(이미 켜진
            // 디스플레이에 대한 켜기 커밋도 1001 로 실패한다 — 실측). 화면이
            // 실제로 켜져 있는지부터 확인해야 로그와 메뉴가 사실을 말한다.
            // 안전망의 중복 시도 처리와 같은 방식이다.
            if DisplayInfo.activeDisplays().contains(id) {
                builtinOff = false
                lastError = nil
                Log.write("[동작] 이미 켜져 있음(중복 시도)")
                return
            }
            lastError = error.localizedDescription
            Log.write("[동작] 내장 켜기 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 로그인 시 실행

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // .app 번들 밖(순수 실행 파일)에서 돌리면 등록이 실패할 수 있다.
            lastError = "로그인 시 실행 설정 실패: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

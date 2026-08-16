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

    /// Command 연타 비상 탈출 사용 여부.
    @Published var emergencyUnlockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(emergencyUnlockEnabled, forKey: Self.emergencyKey)
            applyEmergencyUnlock(requestingPermission: emergencyUnlockEnabled != oldValue)
        }
    }
    /// 손쉬운 사용 권한 상태. 시스템 설정에서 바뀌므로 워치독이 주기적으로 갱신한다.
    @Published private(set) var accessibilityTrusted = false

    var skyLightAvailable: Bool { SkyLight.shared != nil }

    /// 이 Mac 에서 앱이 제 역할을 할 수 있는지. 둘 중 하나라도 없으면 UI 를 잠근다.
    var isUsable: Bool { skyLightAvailable && hasBuiltinDisplay }

    private static let autoModeKey = "autoMode"
    private static let emergencyKey = "emergencyUnlockEnabled"
    private static let emergencyPromptedKey = "emergencyPermissionPrompted"
    /// 재구성 콜백이 실제 감지를 담당하므로 이 폴링은 예비 수단이다. 넉넉하게 둔다.
    private static let watchdogInterval: TimeInterval = 5
    /// 깨어난 뒤 이 시간 안에 들어온 디스플레이 추가는 "복원"으로 보고 무시한다.
    private static let wakeSettleWindow: TimeInterval = 5

    private var emergencyUnlock: EmergencyUnlock?

    /// 자동 모드가 꺼진 상태에서 사용자가 직접 끈 경우에만 true.
    /// 규칙 2가 곧바로 되돌리는 것을 막는다.
    private var manuallyDisabled = false
    /// 자동 끄기 무장 상태. 깨어난 직후에는 해제된다 — ``handleWake()`` 참고.
    private var autoDisableArmed = true
    private var lastWakeAt = Date.distantPast
    private var pendingEvaluation: DispatchWorkItem?
    private var watchdog: Timer?
    /// 내장 디스플레이 ID. 꺼진 뒤에는 조회되지 않으므로 ``BuiltinDisplay`` 가 기억한다.
    private var builtinDisplayID: CGDirectDisplayID? { BuiltinDisplay.resolve() }

    private init() {
        autoMode = UserDefaults.standard.bool(forKey: Self.autoModeKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // 비상 탈출은 기본값 켜짐. 한 번이라도 화면을 잃으면 메뉴에 접근할 수 없으므로
        // 사용자가 미리 켜두기를 기대하기보다 기본으로 제공하는 편이 안전하다.
        emergencyUnlockEnabled = UserDefaults.standard.object(forKey: Self.emergencyKey) as? Bool ?? true

        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.write("[AppKit] 화면 구성 변경 알림")
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
    func manualEnable() {
        manuallyDisabled = false
        Log.write("[조작] 수동 켜기")
        autoMode = false
        enableBuiltin()
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

    private func applyEmergencyUnlock(requestingPermission: Bool) {
        guard let emergencyUnlock else { return }
        guard emergencyUnlockEnabled else {
            emergencyUnlock.stop()
            refreshAccessibilityStatus()
            return
        }
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
        if emergencyUnlockEnabled, trusted, !emergencyUnlock.isRunning {
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
    private func prepareForSleep() {
        Log.write("[시스템] 잠들기 — 내장 디스플레이 선복구")
        enableBuiltin()
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
        Log.write("[시스템] 깨어남 — 내장 복구 후 자동 끄기 보류")
        autoDisableArmed = false
        lastWakeAt = Date()
        enableBuiltin()
        handleReconfiguration()
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

        if externals.isEmpty {
            // 외장이 하나도 없는 상태를 지나갔다면, 다음에 붙는 것은 진짜 연결이다.
            if !autoDisableArmed {
                autoDisableArmed = true
                Log.write("[자동] 외장 0개 확인 → 자동 끄기 재무장")
            }
            // 규칙 1: 외장이 없으면 무조건 켠다.
            if isOff {
                Log.write("[규칙1] 외장 0개 + 내장 꺼짐 → 복구")
                enableBuiltin()
            }
        } else if autoMode {
            // 규칙 3. 단, 깨어난 직후 관찰만으로는 끄지 않는다(handleWake 참고).
            if !isOff, autoDisableArmed { disableBuiltin() }
        } else if isOff, !manuallyDisabled {
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
        } catch {
            lastError = error.localizedDescription
            Log.write("[동작] 내장 끄기 실패: \(error.localizedDescription)")
        }
    }

    private func enableBuiltin() {
        guard let skyLight = SkyLight.shared, let id = builtinDisplayID else { return }
        do {
            // session: appOnly 로 켜면 이 프로세스가 끝날 때 도로 꺼진다.
            try skyLight.setDisplay(id, enabled: true, scope: .session)
            builtinOff = false
            lastError = nil
            Log.write("[동작] 내장(id=\(id)) 켬. active=\(DisplayInfo.activeDisplays().sorted())")
        } catch {
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

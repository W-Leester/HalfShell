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
    DispatchQueue.main.async {
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
                Log.write("[설정] 자동 모드 \(autoMode ? "켜짐" : "꺼짐")")
            }
            evaluate()
        }
    }
    @Published private(set) var builtinOff = false
    @Published private(set) var externalConnected = false
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

    private static let autoModeKey = "autoMode"
    private static let emergencyKey = "emergencyUnlockEnabled"
    private static let emergencyPromptedKey = "emergencyPermissionPrompted"
    private static let watchdogInterval: TimeInterval = 2

    private var emergencyUnlock: EmergencyUnlock?

    /// 자동 모드가 꺼진 상태에서 사용자가 직접 끈 경우에만 true.
    /// 규칙 2가 곧바로 되돌리는 것을 막는다.
    private var manuallyDisabled = false
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

        // 잠자기에서 깨어날 때 디스플레이 구성이 바뀌어 있을 수 있다.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.write("[시스템] 깨어남")
            MainActor.assumeIsolated { self?.handleReconfiguration() }
        }

        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
                self?.refreshAccessibilityStatus()
            }
        }

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
        Log.write("[조작] 수동 끄기")
        disableBuiltin()
    }

    func manualEnable() {
        manuallyDisabled = false
        Log.write("[조작] 수동 켜기")
        if autoMode {
            autoMode = false  // didSet → evaluate() 가 규칙 2로 복구한다
        } else {
            enableBuiltin()
        }
    }

    /// Command 연타로 발동하는 비상 복구.
    ///
    /// 자동 모드까지 끄는 것이 핵심이다. 켜기만 하면 규칙 3이 곧바로 다시 꺼버려서
    /// 사용자는 "눌러도 안 된다"고 느끼게 된다.
    func emergencyRestore() {
        manualEnable()
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
        // 가상 자리표시자는 화면으로 세지 않는다. 그것을 외장으로 오인하면
        // "외장이 있으니 내장은 꺼둬도 된다"고 판단해 복구를 놓친다.
        let active = Set(DisplayInfo.realActiveDisplays())
        let externals = active.filter { CGDisplayIsBuiltin($0) == 0 }
        // 워치독이 2초마다 도므로, 값이 실제로 바뀔 때만 발행해 UI 갱신을 아낀다.
        if externalConnected != !externals.isEmpty { externalConnected = !externals.isEmpty }

        guard let builtin = builtinDisplayID else {
            if builtinOff { builtinOff = false }
            return
        }
        let isOff = !active.contains(builtin)
        if builtinOff != isOff { builtinOff = isOff }

        if externals.isEmpty {
            // 규칙 1: 외장이 없으면 무조건 켠다.
            if isOff {
                Log.write("[규칙1] 외장 0개 + 내장 꺼짐 → 복구")
                enableBuiltin()
            }
        } else if autoMode {
            // 규칙 3
            if !isOff { disableBuiltin() }
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

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

    var skyLightAvailable: Bool { SkyLight.shared != nil }

    private static let autoModeKey = "autoMode"
    private static let watchdogInterval: TimeInterval = 2

    /// 자동 모드가 꺼진 상태에서 사용자가 직접 끈 경우에만 true.
    /// 규칙 2가 곧바로 되돌리는 것을 막는다.
    private var manuallyDisabled = false
    private var pendingEvaluation: DispatchWorkItem?
    private var watchdog: Timer?
    private var lastKnownBuiltinID: CGDirectDisplayID?

    /// 내장 디스플레이 ID.
    ///
    /// 재구성 과정에서 ID 가 바뀌고 일시적으로 조회되지 않는 순간이 있어서(실측 확인)
    /// 영구 캐시는 위험하다. 매번 새로 찾되, 못 찾은 순간에는 마지막으로 확인된 값을
    /// 쓴다.
    private var builtinDisplayID: CGDirectDisplayID? {
        if let found = DisplayInfo.findBuiltinDisplay() {
            lastKnownBuiltinID = found
            return found
        }
        return lastKnownBuiltinID
    }

    private init() {
        autoMode = UserDefaults.standard.bool(forKey: Self.autoModeKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled

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
            MainActor.assumeIsolated { self?.evaluate() }
        }

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
        let active = Set(DisplayInfo.activeDisplays())
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
            // 규칙 1: 외장이 없으면 무조건 켠다. ID 가 흔들릴 수 있으므로 후보를 모두 켠다.
            if isOff {
                Log.write("[규칙1] 외장 0개 + 내장 꺼짐 → 복구")
                if let skyLight = SkyLight.shared,
                   (try? skyLight.setDisplays(DisplayInfo.builtinCandidates(), enabled: true)) != nil {
                    builtinOff = false
                    Log.write("[규칙1] 복구 완료. active=\(DisplayInfo.activeDisplays().sorted())")
                } else {
                    enableBuiltin()
                }
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
            try skyLight.setDisplay(id, enabled: false)
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
            try skyLight.setDisplay(id, enabled: true)
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

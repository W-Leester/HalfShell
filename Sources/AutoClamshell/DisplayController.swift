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
    DispatchQueue.main.async {
        DisplayController.shared.handleReconfiguration()
    }
}

/// 디스플레이 토폴로지를 감시하면서 내장 디스플레이를 끄고 켜는 상태 머신.
///
/// 규칙(우선순위 순):
///  1. 외장이 하나도 없으면 무조건 내장을 켠다. 다른 모든 규칙보다 우선한다.
///     — 화면이 하나도 없어서 조작이 불가능해지는 상황을 막는 최후의 방어선.
///  2. 자동 모드가 꺼져 있으면, 이번 세션에서 사용자가 직접 끈 게 아닌 한 내장을 켠다.
///     — 이전 인스턴스가 크래시했거나 다른 앱(Lunar 등)이 꺼둔 상태를 자가 치유한다.
///  3. 자동 모드 + 외장 존재 → 내장을 끈다.
///
/// 감시는 세 경로를 겹쳐 둔다. CoreGraphics 재구성 콜백(가장 빠름),
/// AppKit 화면 변경 알림, 그리고 2초 주기 워치독. 앞의 두 알림이 오지 않는
/// 상황(특히 활성 디스플레이가 0개가 되는 순간)에도 워치독이 반드시 복구한다.
@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    @Published var autoMode: Bool {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: Self.autoModeKey)
            if autoMode != oldValue { manuallyDisabled = false }
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
    private var cachedBuiltinID: CGDirectDisplayID?

    /// 내장 디스플레이 ID. 기기 수명 내내 바뀌지 않으므로 한 번 찾으면 캐시한다.
    private var builtinDisplayID: CGDirectDisplayID? {
        if let cachedBuiltinID { return cachedBuiltinID }
        cachedBuiltinID = Self.findBuiltinDisplay()
        return cachedBuiltinID
    }

    private init() {
        autoMode = UserDefaults.standard.bool(forKey: Self.autoModeKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleReconfiguration() }
        }

        // 잠자기에서 깨어날 때 디스플레이 구성이 바뀌어 있을 수 있다.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleReconfiguration() }
        }

        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }

        evaluate()
    }

    // MARK: - 사용자 조작

    func manualDisable() {
        guard externalConnected else { return }
        manuallyDisabled = !autoMode
        disableBuiltin()
    }

    func manualEnable() {
        manuallyDisabled = false
        if autoMode {
            autoMode = false  // didSet → evaluate() 가 규칙 2로 복구한다
        } else {
            enableBuiltin()
        }
    }

    /// 종료 직전 복구. forAppOnly 커밋이 이중 안전망이지만 명시적으로도 되돌린다.
    func restoreForQuit() {
        watchdog?.invalidate()
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
        let active = Set(Self.activeDisplays())
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
            if isOff { enableBuiltin() }
        } else if autoMode {
            // 규칙 3
            if !isOff { disableBuiltin() }
        } else if isOff, !manuallyDisabled {
            // 규칙 2: 자동 모드가 꺼져 있는데 내장이 꺼져 있다 → 자가 치유
            enableBuiltin()
        }
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// 내장 디스플레이 ID를 찾는다.
    ///
    /// 논리적으로 꺼진 내장 디스플레이는 `CGGetActiveDisplayList` 는 물론
    /// `CGGetOnlineDisplayList` 에서도 사라지므로, 목록 열거로는 절대 찾을 수 없다.
    /// 하지만 ID 자체는 살아 있어서 개별 조회에는 응답한다. 그래서 ID 공간을 훑는다.
    ///
    /// 유효하지 않은 ID도 `CGDisplayIsBuiltin` 에 true 를 돌려주므로 그것만으로는
    /// 구분할 수 없다. 실제 내장 패널은 vendor 번호와 픽셀 크기가 유효하지만,
    /// 유효하지 않은 ID는 vendor 가 0xFFFFFFFF 이고 크기가 0x0 이다.
    private static func findBuiltinDisplay() -> CGDirectDisplayID? {
        for id in CGDirectDisplayID(1)...CGDirectDisplayID(64) {
            guard CGDisplayIsBuiltin(id) != 0 else { continue }
            let vendor = CGDisplayVendorNumber(id)
            guard vendor != 0, vendor != 0xFFFF_FFFF else { continue }
            guard CGDisplayPixelsWide(id) > 0 else { continue }
            return id
        }
        return nil
    }

    // MARK: - 끄기/켜기

    private func disableBuiltin() {
        guard let skyLight = SkyLight.shared, let id = builtinDisplayID else { return }
        do {
            try skyLight.setDisplay(id, enabled: false)
            builtinOff = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func enableBuiltin() {
        guard let skyLight = SkyLight.shared, let id = builtinDisplayID else { return }
        do {
            try skyLight.setDisplay(id, enabled: true)
            builtinOff = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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

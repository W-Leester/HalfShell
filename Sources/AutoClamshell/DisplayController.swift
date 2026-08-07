import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

/// 디스플레이 토폴로지를 감시하면서 내장 디스플레이를 끄고 켜는 상태 머신.
///
/// 규칙:
///  - 자동 모드 ON + 외장 디스플레이 활성 → 내장을 끈다.
///  - 외장이 모두 사라지면 자동 모드와 무관하게 내장을 즉시 복구한다(화면 전멸 방지).
///  - 수동으로 내장을 켜면 자동 모드를 함께 끈다(켜자마자 자동 로직이 도로 꺼버리는 싸움 방지).
///  - 앱 종료 시 내장을 복구한다. 강제 종료되더라도 forAppOnly 커밋이라 OS가 되돌린다.
@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    @Published var autoMode: Bool {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: Self.autoModeKey)
            if autoMode {
                scheduleEvaluation()
            } else if builtinOff {
                enableBuiltin()
            }
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

    /// 내장 디스플레이는 꺼지면 활성 목록에서 사라지므로, 복구를 위해 ID를 기억해 둔다.
    private var builtinID: CGDirectDisplayID?
    private var pendingEvaluation: DispatchWorkItem?

    private init() {
        autoMode = UserDefaults.standard.bool(forKey: Self.autoModeKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEvaluation() }
        }
        scheduleEvaluation()
    }

    // MARK: - 사용자 조작

    func manualDisable() {
        guard externalConnected else { return }
        disableBuiltin()
    }

    func manualEnable() {
        if autoMode {
            autoMode = false  // didSet에서 enableBuiltin까지 수행
        } else {
            enableBuiltin()
        }
    }

    /// 종료 직전 복구. forAppOnly 커밋이 이중 안전망이지만 명시적으로도 되돌린다.
    func restoreForQuit() {
        if builtinOff { enableBuiltin() }
    }

    // MARK: - 토폴로지 감시

    /// 재구성 알림은 한 번의 변경에도 여러 번 몰려오므로 짧게 디바운스한다.
    private func scheduleEvaluation() {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func evaluate() {
        let active = Self.activeDisplays()
        let builtinActive = active.first { CGDisplayIsBuiltin($0) != 0 }
        let externals = active.filter { CGDisplayIsBuiltin($0) == 0 }

        if let builtinActive {
            builtinID = builtinActive
            builtinOff = false
        }
        externalConnected = !externals.isEmpty

        if externals.isEmpty {
            // 외장이 사라졌다: 내장이 꺼진 채면 무조건 복구 (안전 규칙)
            if builtinOff { enableBuiltin() }
        } else if autoMode, builtinActive != nil {
            disableBuiltin()
        }
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - 끄기/켜기

    private func disableBuiltin() {
        guard let skyLight = SkyLight.shared, let id = builtinID, !builtinOff else { return }
        do {
            try skyLight.setDisplay(id, enabled: false)
            builtinOff = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func enableBuiltin() {
        guard let skyLight = SkyLight.shared, let id = builtinID else { return }
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

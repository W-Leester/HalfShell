import AppKit
import SwiftUI

@main
struct HalfShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DisplayController.shared
    @StateObject private var updates = UpdateMonitor.shared
    // 언어가 바뀌면 메뉴를 다시 그리기 위해 관찰한다.
    @StateObject private var l10n = L10n.shared

    var body: some Scene {
        MenuBarExtra {
            Toggle(L("외장 연결 시 내장 디스플레이 자동 끄기"), isOn: $controller.autoMode)
                .disabled(!controller.isUsable)

            Divider()

            if controller.builtinOff {
                Button(L("내장 디스플레이 켜기")) { controller.manualEnable() }
            } else {
                Button(L("내장 디스플레이 지금 끄기")) { controller.manualDisable() }
                    .disabled(!controller.externalConnected || !controller.isUsable)
            }

            Text(statusLine)

            // 이 앱이 아무 일도 할 수 없는 Mac 이라면 이유를 분명히 알린다.
            if !controller.hasBuiltinDisplay {
                Text(L("이 Mac에는 내장 디스플레이가 없어 사용할 수 없습니다"))
            } else if !controller.skyLightAvailable {
                Text(L("이 Mac에서는 SkyLight API를 사용할 수 없습니다"))
            }
            if let error = controller.lastError {
                Text(L("오류: %@", error))
            }

            Divider()

            // 끌 수 없는 기능이므로 토글이 아니라 안내로 둔다.
            if controller.accessibilityTrusted {
                Text(L("화면 복구: Command %lld번 연타", EmergencyUnlock.requiredTaps))
            } else {
                Text(L("화면 복구 단축키 작동 안 함 — 손쉬운 사용 권한 필요"))
            }

            Divider()

            Toggle(L("로그인 시 실행"), isOn: $controller.launchAtLogin)
            if let version = updates.availableVersion {
                Button(L("새 버전 %@ 받기…", version)) { updates.openReleasesPage() }
            }
            Picker(L("언어"), selection: $l10n.language) {
                ForEach(Language.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Button(L("HalfShell 정보 보기")) { SetupWindowController.shared.show() }

            Divider()

            Button(L("종료")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: controller.builtinOff ? "laptopcomputer.slash" : "laptopcomputer")
        }
    }

    private var statusLine: String {
        if controller.builtinOff { return L("내장 디스플레이: 꺼짐") }
        return controller.externalConnected
            ? L("외장 디스플레이: 연결됨") : L("외장 디스플레이: 없음")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// App Nap 방지 토큰. 해제되면 다시 App Nap 대상이 되므로 앱 수명 내내 잡고 있는다.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 화면이 0개가 되면 이 앱은 창도 입력도 없는 완전한 백그라운드 프로세스가 되어
        // App Nap 대상이 된다. 그러면 타이머가 수십 초씩 밀려서, 정작 복구가 가장
        // 급한 순간에 감시가 돌지 않는다. 유휴 시스템 잠자기는 그대로 허용한다.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "디스플레이 상태 감시"
        )

        Telemetry.start()
        Log.startSession("HalfShell \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        SafetyNet.shared.start()
        _ = DisplayController.shared
        // 설치 직후 한 번은 눈에 보이는 곳에서 안내한다. 특히 손쉬운 사용 권한은
        // 안 켜두면 비상 탈출이 조용히 죽는다.
        SetupWindowController.shared.showIfNeeded()
        UpdateMonitor.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SafetyNet.shared.stop()
        MainActor.assumeIsolated { DisplayController.shared.restoreForQuit() }
    }
}

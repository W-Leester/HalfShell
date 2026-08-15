import AppKit
import SwiftUI

@main
struct HalfShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DisplayController.shared

    var body: some Scene {
        MenuBarExtra {
            Toggle("외장 연결 시 내장 디스플레이 자동 끄기", isOn: $controller.autoMode)
                .disabled(!controller.skyLightAvailable)

            Divider()

            if controller.builtinOff {
                Button("내장 디스플레이 켜기") { controller.manualEnable() }
            } else {
                Button("내장 디스플레이 지금 끄기") { controller.manualDisable() }
                    .disabled(!controller.externalConnected || !controller.skyLightAvailable)
            }

            Text(statusLine)

            if !controller.skyLightAvailable {
                Text("이 macOS 버전에서는 SkyLight API를 사용할 수 없습니다")
            }
            if let error = controller.lastError {
                Text("오류: \(error)")
            }

            Divider()

            Toggle("비상 탈출: Command \(EmergencyUnlock.requiredTaps)번 연타",
                   isOn: $controller.emergencyUnlockEnabled)
            if controller.emergencyUnlockEnabled, !controller.accessibilityTrusted {
                Text("작동 안 함 — 개인정보 보호 및 보안 → 손쉬운 사용에서 허용 필요")
            }

            Divider()

            Toggle("로그인 시 실행", isOn: $controller.launchAtLogin)
            Button("로그 열기") { NSWorkspace.shared.open(Log.fileURL) }

            Divider()

            Button("종료") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: controller.builtinOff ? "laptopcomputer.slash" : "laptopcomputer")
        }
    }

    private var statusLine: String {
        if controller.builtinOff { return "내장 디스플레이: 꺼짐" }
        return controller.externalConnected ? "외장 디스플레이: 연결됨" : "외장 디스플레이: 없음"
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

        Log.startSession("HalfShell \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        SafetyNet.shared.start()
        _ = DisplayController.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        SafetyNet.shared.stop()
        MainActor.assumeIsolated { DisplayController.shared.restoreForQuit() }
    }
}

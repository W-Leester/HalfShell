import AppKit
import SwiftUI

@main
struct AutoClamshellApp: App {
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

            Toggle("로그인 시 실행", isOn: $controller.launchAtLogin)

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { DisplayController.shared.restoreForQuit() }
    }
}

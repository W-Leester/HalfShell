import AppKit
import SwiftUI

/// 첫 실행 안내 창.
///
/// 이 앱은 메뉴바에만 존재해서 사용자가 설정을 찾아 들어가기 어렵다. 특히
/// **손쉬운 사용 권한은 안 켜두면 비상 탈출이 조용히 죽는다.** 실제로 그 상태에서
/// 검은 화면을 만나 강제 재부팅까지 간 적이 있다(장애 기록 사건 3).
/// 그래서 설치 직후 한 번은 눈에 보이는 곳에서 안내한다.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()

    private var window: NSWindow?
    private static let completedKey = "setupCompleted"

    /// 처음 실행이거나 아직 권한이 없으면 자동으로 띄운다.
    func showIfNeeded() {
        let done = UserDefaults.standard.bool(forKey: Self.completedKey)
        guard !done else { return }
        show()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "HalfShell 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}

private struct SetupView: View {
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HalfShell 설정")
                    .font(.title2).bold()
                Text("뚜껑을 연 채로 내장 디스플레이만 끄고 외장만 사용합니다.\n"
                    + "클램쉘과 화면 구성은 같지만, 뚜껑을 닫지 않아 발열이 덜합니다.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if !controller.hasBuiltinDisplay {
                Label("이 Mac에는 내장 디스플레이가 없어 사용할 수 없습니다.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Toggle("외장 연결 시 내장 디스플레이 자동 끄기", isOn: $controller.autoMode)
                Toggle("로그인 시 자동 실행", isOn: $controller.launchAtLogin)

                Divider()

                // 여기가 이 창의 존재 이유다.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: controller.accessibilityTrusted
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(controller.accessibilityTrusted ? .green : .orange)
                        Text("비상 탈출 — Command 키 5번 연타")
                            .bold()
                    }
                    Text(controller.accessibilityTrusted
                         ? "준비됐습니다. 화면이 보이지 않을 때 Command 를 2초 안에 5번 누르면 내장 화면이 켜집니다."
                         : "손쉬운 사용 권한이 필요합니다. 지금은 작동하지 않습니다.\n"
                           + "화면이 검게 남았을 때 손만으로 빠져나올 수 있는 유일한 방법이므로 켜두시길 권합니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !controller.accessibilityTrusted {
                        Button("손쉬운 사용 설정 열기…") {
                            controller.requestAccessibilityPermission()
                        }
                        Text("시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서 HalfShell 을 켭니다.\n"
                            + "이름이 같은 \"시스템 설정 → 손쉬운 사용\"은 다른 곳입니다.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            HStack {
                Text("나중에 메뉴바 아이콘에서 다시 열 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("완료") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

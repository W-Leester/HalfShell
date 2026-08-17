import AppKit
import SwiftUI

/// 현재 설정을 한눈에 보여주는 창.
///
/// 이 앱은 메뉴바에만 존재해서 상태를 파악하기 어렵다. 특히 **손쉬운 사용 권한은
/// 안 켜두면 화면 복구 단축키가 조용히 죽는다.** 실제로 그 상태에서 검은 화면을 만나
/// 강제 재부팅까지 간 적이 있다(장애 기록 사건 3-B).
///
/// 값을 바꾸는 곳은 메뉴바다. 여기서는 **보여주기만 한다** — 같은 설정을 두 곳에서
/// 바꿀 수 있으면 어느 쪽이 진짜인지 헷갈린다.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()

    private var window: NSWindow?
    private static let completedKey = "setupCompleted"

    /// 처음 실행이면 자동으로 띄운다.
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        show()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "HalfShell"
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
    @ObservedObject private var updates = UpdateMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if !controller.hasBuiltinDisplay {
                Label("이 Mac에는 내장 디스플레이가 없어 사용할 수 없습니다.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                settingsStatus
                Divider()
                emergencySection
            }

            Divider()
            footer
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { updates.checkNow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("HalfShell").font(.title2).bold()
                Text("버전 \(UpdateCheck.currentVersion) (빌드 \(UpdateCheck.buildNumber))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("뚜껑을 연 채로 내장 디스플레이만 끄고 외장만 사용합니다.\n"
                + "클램쉘과 화면 구성은 같지만, 뚜껑을 닫지 않아 발열이 덜합니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 값 변경은 메뉴바에서 한다. 여기서는 상태만 보여준다.
    private var settingsStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("외장 연결 시 내장 디스플레이 자동 끄기", on: controller.autoMode)
            statusRow("로그인 시 자동 실행", on: controller.launchAtLogin)
            Text("변경은 메뉴바 아이콘에서 합니다.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func statusRow(_ title: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? .green : .secondary)
            Text(title)
            Spacer()
            Text(on ? "켜짐" : "꺼짐")
                .font(.callout)
                .foregroundStyle(on ? .primary : .secondary)
        }
    }

    private var emergencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: controller.accessibilityTrusted
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(controller.accessibilityTrusted ? .green : .orange)
                Text("화면 복구 단축키 — Command 5번 연타").bold()
                Spacer()
                Text(controller.accessibilityTrusted ? "준비됨" : "작동 안 함")
                    .font(.callout)
                    .foregroundStyle(controller.accessibilityTrusted ? Color.primary : Color.orange)
            }
            Text(controller.accessibilityTrusted
                 ? "화면이 보이지 않을 때 Command 를 4초 안에 5번 누르면 내장 화면이 켜집니다."
                 : "손쉬운 사용 권한이 필요합니다. 화면이 검게 남았을 때 손만으로 빠져나올 수 "
                   + "있는 유일한 방법이므로 켜두시길 권합니다.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !controller.accessibilityTrusted {
                Button("손쉬운 사용 설정 열기…") { controller.requestAccessibilityPermission() }
                Text("시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서 HalfShell 을 켭니다.\n"
                    + "이름이 같은 \"시스템 설정 → 손쉬운 사용\"은 다른 곳입니다.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let version = updates.availableVersion {
                Button("새 버전 \(version) 받기") { updates.openReleasesPage() }
            } else {
                Text("업데이트는 하루 한 번 자동으로 확인합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("확인") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

import AppKit
import SwiftUI

/// 앱 안에서 바로 오류를 신고하는 창.
///
/// GitHub 이슈를 앱이 직접 만들려면 쓰기 권한이 있는 토큰이 필요하고, 배포본에
/// 토큰을 심으면 **누구나 꺼내 쓸 수 있다.** 그래서 이미 붙어 있는 Sentry 를 통로로
/// 쓴다 — 토큰도 서버도 필요 없고, 사고 보고가 한곳에 모인다.
///
/// 보내는 순간까지 사용자가 무엇이 담기는지 볼 수 있어야 한다. 화면에 그대로 보여준다.
@MainActor
final class ReportWindowController: NSObject, NSWindowDelegate {
    static let shared = ReportWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ReportView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "오류 신고"
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

    func close() { window?.close() }
}

private struct ReportView: View {
    @State private var text = ""
    @State private var sent = false

    private var canSendInApp: Bool { Telemetry.isEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("무슨 일이 있었나요?").font(.headline)
            Text("예: 독을 뽑고 뚜껑을 열었더니 화면이 검은 채였습니다.")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            DisclosureGroup("함께 보내는 정보") {
                ScrollView {
                    Text(IssueReport.diagnosticsOnly())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
            }

            if sent {
                Label("보냈습니다. 고맙습니다.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !canSendInApp {
                // 자동 전송이 꺼져 있으면 앱이 대신 보낼 수 없다. 브라우저 경로로 안내한다.
                Text("오류 보고서 자동 전송이 꺼져 있어 앱에서 바로 보낼 수 없습니다.\n"
                    + "브라우저로 신고하거나, HalfShell 정보 창에서 자동 전송을 켜주세요.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("브라우저로 신고") { IssueReport.openIssuePage(userText: text) }
                Spacer()
                Button("닫기") { ReportWindowController.shared.close() }
                Button("보내기") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSendInApp || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func send() {
        Telemetry.report("사용자 신고: \(text.prefix(120))", extra: [
            "userReport": text,
            "diagnostics": IssueReport.diagnosticsOnly(),
        ])
        sent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            ReportWindowController.shared.close()
        }
    }
}

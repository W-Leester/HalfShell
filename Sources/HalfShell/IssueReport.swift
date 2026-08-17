import AppKit
import CoreGraphics
import Foundation

/// 오류 신고서를 만들어 GitHub 이슈 작성 화면을 연다.
///
/// **자동으로 보내지 않는다.** 로그에는 사용자의 모니터 모델과 사용 시각이 담긴다.
/// 민감한 정보는 아니지만 그래도 남의 기기에서 수집한 자료를 본인 확인 없이
/// 전송하는 것은 옳지 않다. 내용을 채워서 보여주고, 보낼지는 사용자가 정한다.
///
/// 서버가 필요 없다는 이점도 있다. GitHub 이슈 작성 화면에 제목과 본문을 미리
/// 채워 넣는 것만으로 신고 경로가 완성된다.
enum IssueReport {
    private static let issueBase = "https://github.com/W-Leester/HalfShell/issues/new"
    /// URL 길이에는 현실적인 한계가 있어 로그는 최근 것만 싣는다.
    private static let logTailLines = 40

    static func compose() -> String {
        var lines: [String] = []
        lines.append("## 무슨 일이 있었나요")
        lines.append("")
        lines.append("(여기에 상황을 적어주세요. 예: 독을 뽑고 뚜껑을 열었더니 화면이 검은 채였습니다)")
        lines.append("")
        lines.append("## 환경")
        lines.append("")
        lines.append("- HalfShell \(UpdateCheck.currentVersion)")
        lines.append("- \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- \(hardwareModel())")
        lines.append("- 디스플레이: \(displaySummary())")
        lines.append("")
        lines.append("## 최근 로그")
        lines.append("")
        lines.append("```")
        lines.append(recentLog())
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    static func openIssuePage() {
        var components = URLComponents(string: issueBase)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[신고] "),
            URLQueryItem(name: "body", value: compose()),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 수집

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "모델 확인 불가" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func displaySummary() -> String {
        let ids = DisplayInfo.activeDisplays()
        guard !ids.isEmpty else { return "활성 없음" }
        return ids.sorted().map { id in
            "\(id)(\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
                + " builtin=\(CGDisplayIsBuiltin(id) != 0))"
        }.joined(separator: " ")
    }

    private static func recentLog() -> String {
        guard let text = try? String(contentsOf: Log.fileURL, encoding: .utf8) else {
            return "(로그를 읽지 못했습니다)"
        }
        return text.split(separator: "\n").suffix(logTailLines).joined(separator: "\n")
    }
}

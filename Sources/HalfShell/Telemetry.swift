import Foundation
import Sentry

/// 오류 자동 보고.
///
/// 크래시는 SDK 가 알아서 수집한다. 문제는 **지금까지 겪은 네 번의 사고가 모두
/// 크래시가 아니었다**는 점이다 — 앱은 멀쩡히 살아서 잘못된 판단을 내리고 화면을
/// 검은 채로 뒀다. 그래서 자동 수집에만 기대면 정작 중요한 사고를 하나도 못 잡는다.
/// 크래시 수집은 그대로 두고, 우리가 사고라고 판단한 것을 **추가로** 보낸다.
///
/// 직접 보내는 것은 **넷뿐이다.** 무료 등급이 월 5,000건이고, 무엇보다 흔한 일까지
/// 보내기 시작하면 진짜 사고가 묻힌다.
///
///  1. 복구 재시도를 모두 소진 — 화면이 검은 채로 남았다는 뜻. 가장 중요하다.
///  2. 안전망 복구가 연속 실패 — 최후 방어선이 무너지는 중이다.
///  3. SkyLight 심볼을 찾지 못함 — macOS 업데이트로 Apple 이 우리를 끊었다는 신호.
///     사용자 신고를 기다리면 늦다. 이걸로 즉시 알 수 있다.
///  4. 느린 커밋이 반복됨 — 배터리 사고의 신호. ``noteSlowCommit(_:seconds:)`` 참고.
///
/// 개인정보: 로그 본문이나 사용자 식별 정보는 보내지 않는다. 앱 버전, macOS 버전,
/// 기종, 그리고 위 사건의 종류와 관련 수치만 담는다.
enum Telemetry {
    /// Info.plist 의 `SentryDSN` 에서 읽는다. 비어 있으면 통째로 비활성이다.
    /// 소스에 박지 않아야 배포본마다 다른 값을 쓰거나 아예 끌 수 있다.
    private static var dsn: String? {
        guard let value = Bundle.main.infoDictionary?["SentryDSN"] as? String,
              !value.isEmpty, !value.hasPrefix("$")
        else { return nil }
        return value
    }

    private static let optOutKey = "telemetryDisabled"

    /// 사용자가 끌 수 있어야 한다. 남의 기기에서 나가는 자료다.
    static var isEnabled: Bool {
        get { dsn != nil && !UserDefaults.standard.bool(forKey: optOutKey) }
        set { UserDefaults.standard.set(!newValue, forKey: optOutKey) }
    }

    /// DSN 이 아예 없으면 사용자에게 설정 항목을 보여줄 이유도 없다.
    static var isConfigured: Bool { dsn != nil }

    private static var started = false

    static func start() {
        guard !started, isEnabled, let dsn else { return }
        started = true
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "halfshell@\(UpdateCheck.currentVersion)"
            // 이 앱은 SkyLight 커밋이 메인 스레드를 10초씩 잡는 것을 실측했다.
            // 그런 멈춤은 사용자에게 그대로 체감되므로 함께 수집한다.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 5
            // 화면·입력을 다루는 앱이라 개인정보에 민감하다. 기본 수집을 최소화한다.
            // (화면 캡처·뷰 계층 첨부 옵션은 iOS 전용이라 macOS 에는 없다)
            options.sendDefaultPii = false
        }
        Log.write("[텔레메트리] 오류 자동 보고 시작")
    }

    static func stop() {
        guard started else { return }
        SentrySDK.close()
        started = false
        Log.write("[텔레메트리] 오류 자동 보고 중지")
    }

    // MARK: - 느린 커밋 추적

    /// 이 시간을 넘는 커밋을 "느리다"고 본다. 실측에서 실패하는 커밋은 약 10초를 잡았다.
    private static let slowCommitThreshold: TimeInterval = 2
    /// 이 횟수를 넘겨 반복되면 구조적 문제로 보고 보고한다.
    private static let slowCommitBurst = 5
    /// 이 시간 안에 반복된 것만 센다.
    private static let slowCommitWindow: TimeInterval = 300

    private static let slowLock = NSLock()
    private static var slowCommits: [Date] = []
    private static var slowReportedAt = Date.distantPast

    /// 오래 걸린 SkyLight 커밋을 기록한다.
    ///
    /// 한 번 느린 것은 흔한 일이라 알릴 가치가 없다. **반복되는 것이 신호다** —
    /// 배터리 사고가 정확히 그 모양이었다(10초 블로킹이 12초마다, 3시간 동안).
    /// 그때 이 추적이 있었다면 훨씬 빨리 잡았을 것이다.
    /// Lunar 의 `RepeatingHang` 이 같은 발상이다.
    static func noteSlowCommit(_ operation: String, seconds: TimeInterval) {
        guard seconds >= slowCommitThreshold else { return }
        slowLock.lock()
        let now = Date()
        slowCommits.append(now)
        slowCommits.removeAll { now.timeIntervalSince($0) > slowCommitWindow }
        let count = slowCommits.count
        let shouldReport = count >= slowCommitBurst
            && now.timeIntervalSince(slowReportedAt) > slowCommitWindow
        if shouldReport { slowReportedAt = now }
        slowLock.unlock()

        Log.write(String(format: "[성능] 느린 커밋 %@ %.1f초 (최근 %d분간 %d회)",
                         operation, seconds, Int(slowCommitWindow / 60), count))
        guard shouldReport else { return }
        report("SkyLight 커밋이 반복적으로 느림 — 구조적 문제 가능성", extra: [
            "operation": operation,
            "lastDurationSeconds": seconds,
            "countInWindow": count,
            "windowMinutes": Int(slowCommitWindow / 60),
        ])
    }

    /// 사고를 보고한다. 로그에도 같은 내용을 남겨 사용자가 무엇이 나갔는지 볼 수 있게 한다.
    static func report(_ summary: String, extra: [String: Any] = [:]) {
        Log.write("[텔레메트리] 보고: \(summary) \(extra.isEmpty ? "" : String(describing: extra))")
        guard isEnabled, started else { return }
        SentrySDK.capture(message: summary) { scope in
            scope.setLevel(.error)
            for (key, value) in extra {
                scope.setExtra(value: value, key: key)
            }
        }
    }
}

import Foundation
import Sentry

/// 오류 자동 보고.
///
/// **이 앱은 크래시하지 않는다.** 잘못된 판단을 내리고 화면을 검은 채로 둘 뿐이다.
/// 그래서 Sentry 의 자동 크래시 수집만으로는 정작 중요한 사고를 하나도 못 잡는다.
/// 우리가 직접 "이건 사고다"라고 판단해 보내야 한다.
///
/// 보내는 것은 **셋뿐이다.** 무료 등급이 월 5,000건이고, 무엇보다 흔한 일까지
/// 보내기 시작하면 진짜 사고가 묻힌다.
///
///  1. 복구 재시도를 모두 소진 — 화면이 검은 채로 남았다는 뜻. 가장 중요하다.
///  2. 안전망 복구가 연속 실패 — 최후 방어선이 무너지는 중이다.
///  3. SkyLight 심볼을 찾지 못함 — macOS 업데이트로 Apple 이 우리를 끊었다는 신호.
///     사용자 신고를 기다리면 늦다. 이걸로 즉시 알 수 있다.
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

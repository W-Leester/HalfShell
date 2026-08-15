import CoreGraphics
import Foundation

/// 최후의 방어선. 메인 런루프와 **완전히 무관하게** 도는 감시 타이머다.
///
/// 화면이 하나도 없는 상태가 되면 이 앱은 창도 없고 사용자 입력도 없는 완전한
/// 백그라운드 프로세스가 된다. 이때 App Nap 이 메인 런루프의 `Timer` 를 수십 초씩
/// 지연시킬 수 있어서, 정작 복구가 가장 급한 순간에 워치독이 돌지 않는다.
/// 그래서 이쪽은 전용 `DispatchQueue` 위의 `DispatchSourceTimer` 를 쓰고,
/// 판단과 복구를 그 큐에서 직접 끝낸다 (MainActor 로 넘기지 않는다).
///
/// 정책은 신경 쓰지 않는다. 오직 한 가지 조건만 본다:
/// **활성 외장이 하나도 없는데 내장도 꺼져 있다 → 무조건 켠다.**
final class SafetyNet {
    static let shared = SafetyNet()

    /// 평상시 주기. 디스플레이 구성이 안정된 동안에는 이 간격으로 확인한다.
    ///
    /// 실제 복구는 재구성 콜백이 켜는 경계 모드가 담당하므로 이 폴링은 알림이
    /// 아예 오지 않는 경우를 대비한 예비 수단이다. 짧게 잡을 이유가 없고,
    /// 배터리로 도는 시간이 대부분이라 넉넉하게 둔다.
    private static let idleInterval: TimeInterval = 5
    /// 평상시 여유. 크게 줘야 커널이 다른 깨우기와 묶어서 처리한다(전력 절약).
    private static let idleLeeway: DispatchTimeInterval = .seconds(2)
    /// 경계 주기. 재구성이 시작되면 이 간격으로 좁혀서 빠르게 복구한다.
    private static let alertInterval: TimeInterval = 0.1
    /// 경계 상태를 유지하는 시간.
    private static let alertDuration: TimeInterval = 6

    private let queue = DispatchQueue(label: "dev.leester.halfshell.safetynet", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var alerting = false
    private var alertDeadline = Date.distantPast
    private var lastSignature = ""
    private var consecutiveFailures = 0
    private var retryNotBefore = Date.distantPast
    private var loggedMissingBuiltin = false

    /// 연속 실패 시 재시도 간격 상한.
    private static let maxBackoff: Double = 60

    private init() {}

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            reschedule(interval: Self.idleInterval)
            source.resume()
            Log.write("[안전망] 시작 (평상시 \(Self.idleInterval)초 / 경계 \(Self.alertInterval)초)")
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// 디스플레이 재구성이 감지되면 호출한다. 잠시 확인 주기를 좁힌다.
    ///
    /// 재구성이 **끝난 뒤에야** 외장이 사라진 것을 알 수 있는데, 그 순간 화면이
    /// 하나도 없으면 사용자는 아무것도 할 수 없다. 평상시 주기(1초)를 기다리는 대신
    /// 0.1초 간격으로 좁혀서 체감 정지 시간을 줄인다.
    func alert() {
        queue.async { [self] in
            alertDeadline = Date().addingTimeInterval(Self.alertDuration)
            guard !alerting else { return }
            alerting = true
            reschedule(interval: Self.alertInterval)
        }
    }

    private func reschedule(interval: TimeInterval) {
        // 경계 모드는 즉시성이 생명이라 여유를 최소로, 평상시에는 크게 준다.
        let leeway: DispatchTimeInterval = interval <= Self.alertInterval
            ? .milliseconds(10)
            : Self.idleLeeway
        timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
    }

    private func tick() {
        if alerting, Date() > alertDeadline {
            alerting = false
            reschedule(interval: Self.idleInterval)
        }

        let all = DisplayInfo.activeDisplays()
        let real = all.filter { !DisplayInfo.isVirtual($0) }

        let signature = "active=\(all.sorted()) 실제=\(real.sorted())"
        if signature != lastSignature {
            lastSignature = signature
            Log.write("[안전망] \(signature)")
        }

        // 활성 목록이 **완전히** 비어 있으면 잠자기 중이다. 복구할 것도 이유도 없다.
        //
        // 진짜 위험 상황과 구분하는 기준이 바로 이것이다. 실제 패널이 모두 사라지면
        // macOS 가 가상 디스플레이를 만들어 두므로 목록이 비지 않는다(active=[12] 같은 꼴).
        // 반대로 잠자기 중에는 목록이 통째로 빈다. 이 구분을 놓쳐서 밤새 잠든 맥을
        // 상대로 복구를 반복하며 배터리를 태운 적이 있다.
        guard !all.isEmpty else {
            clearFailureState()
            return
        }

        // 실제 패널이 하나라도 살아 있으면 할 일이 없다.
        // 여기서 가상 자리표시자를 걸러내는 것이 핵심이다. 그것을 화면으로 세면
        // "화면이 있으니 괜찮다"고 오판해 정작 복구가 필요한 순간을 놓친다.
        guard real.isEmpty else {
            clearFailureState()
            return
        }

        // 연속 실패 시 물러선다. 복구가 안 되는 상황에서 무한 재시도하면
        // 전력만 태운다(커밋 호출이 실패할 때 10초씩 블로킹된다).
        guard Date() >= retryNotBefore else { return }

        guard let target = BuiltinDisplay.resolve() else {
            // 내장 디스플레이가 없는 Mac 이면 이 상태가 계속 유지된다(화면 없이 돌리는
            // Mac mini 등). 5초마다 같은 줄을 남기면 로그만 불어나므로 한 번만 남긴다.
            if !loggedMissingBuiltin {
                loggedMissingBuiltin = true
                Log.write("[안전망] 실제 화면 없음. 복구할 내장 디스플레이가 없어 대기 (이후 생략)")
            }
            return
        }
        loggedMissingBuiltin = false
        Log.write("[안전망] 긴급 — 실제 화면 없음(active=\(all.sorted())). 내장 id=\(target) 복구 시도")
        guard let skyLight = SkyLight.shared else {
            Log.write("[안전망] 실패: SkyLight 사용 불가")
            return
        }
        do {
            // session 범위로 커밋한다. appOnly 로 켜면 이 프로세스가 끝날 때 도로 꺼진다.
            try skyLight.setDisplay(target, enabled: true, scope: .session)
            Log.write("[안전망] 복구 성공. active=\(DisplayInfo.activeDisplays().sorted())")
            clearFailureState()
        } catch {
            // 컨트롤러 쪽 규칙 1 이 먼저 복구했다면 이쪽 트랜잭션은 밀려서 실패한다.
            // 화면이 돌아왔는지부터 확인해야 로그가 사실을 말한다.
            if !DisplayInfo.realActiveDisplays().isEmpty {
                Log.write("[안전망] 이미 복구됨(중복 시도). active=\(DisplayInfo.activeDisplays().sorted())")
                clearFailureState()
                return
            }
            consecutiveFailures += 1
            let backoff = min(pow(2, Double(consecutiveFailures)), Self.maxBackoff)
            retryNotBefore = Date().addingTimeInterval(backoff)
            Log.write("[안전망] 복구 실패(\(consecutiveFailures)회): \(error.localizedDescription) "
                + "— \(Int(backoff))초 뒤 재시도")
        }
    }

    private func clearFailureState() {
        guard consecutiveFailures > 0 else { return }
        consecutiveFailures = 0
        retryNotBefore = .distantPast
    }
}
